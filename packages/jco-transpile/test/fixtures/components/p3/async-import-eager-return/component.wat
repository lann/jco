;; Regression fixture for async-lowered host import return handling.
;;
;; Two invariants are pinned here:
;;
;; 1. (STALE-SUBTASK-EVENT-GUEST-TRAP root cause) 8-bit results lowered by the
;;    metadata-driven lowering intrinsics must write exactly ONE byte: the
;;    `check-u8-result` export surrounds its u8 result slot with canary bytes
;;    and fails if any canary is clobbered (the broken `_lowerFlatU8` wrote a
;;    full u32 per u8, spilling 3 bytes past list/result slots and poisoning
;;    adjacent allocator metadata).
;;
;; 2. (Async import ABI) a fast import may return eagerly with RETURNED (2)
;;    and no subtask handle -- in which case the results must already be
;;    written -- or report STARTED (1) with a handle and deliver RETURNED via
;;    the standard waitable-set event path, with the result written no later
;;    than event delivery, and the subtask must then be droppable.
;;
;; Exports (callback-ABI async lifts) report a diagnostic code via
;; task.return:
;;   0     = eager RETURNED path completed OK (result + canaries verified)
;;   1     = STARTED + event-path lifecycle completed OK
;;   2-9   = specific check failures (see the code sites below)
;;   100+s = unexpected initial status s
;;
;; Status codes (low 4 bits of the lowered call's packed return):
;;   0 = STARTING, 1 = STARTED, 2 = RETURNED
;; Event codes: 1 = SUBTASK; event payload 2 = RETURNED.
(component
  ;; Host-provided async imports
  (import "fast-no-result" (func $fast-no-result async))
  (import "fast-with-result" (func $fast-with-result async (result u32)))
  (import "fast-with-u8-result" (func $fast-with-u8-result async (result u8)))

  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))

  (core module $Core
    (import "" "mem" (memory 1))
    (import "" "task.return" (func $task.return (param i32)))
    (import "" "subtask.drop" (func $subtask.drop (param i32)))
    (import "" "waitable.join" (func $waitable.join (param i32 i32)))
    (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
    (import "" "waitable-set.drop" (func $waitable-set.drop (param i32)))
    (import "" "fast-no-result" (func $fast-no-result (result i32)))
    (import "" "fast-with-result" (func $fast-with-result (param i32) (result i32)))
    (import "" "fast-with-u8-result" (func $fast-with-u8-result (param i32) (result i32)))

    ;; out-pointer for u32/u8 results
    (global $RESULT_PTR i32 (i32.const 16))

    (global $subtask (mut i32) (i32.const 0))
    (global $ws (mut i32) (i32.const 0))
    ;; which post-event verification to run in the shared callback:
    ;; 0 = none, 1 = u32 result, 2 = u8 result + canaries
    (global $verify (mut i32) (i32.const 0))

    ;; Fill RESULT_PTR..+16 with 0xAA canary bytes.
    (func $plant-canaries
      (local $i i32)
      (local.set $i (i32.const 0))
      (block
        (loop
          (i32.store8 (i32.add (global.get $RESULT_PTR) (local.get $i)) (i32.const 0xaa))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if 1 (i32.ge_u (local.get $i) (i32.const 16)))
          (br 0)
        )
      )
    )

    ;; Verify the current $verify mode's result + canaries; 0 = OK.
    (func $verify-result (result i32)
      (block
        (block
          (br_if 0 (i32.eq (global.get $verify) (i32.const 1)))
          (br_if 1 (i32.eq (global.get $verify) (i32.const 2)))
          (return (i32.const 0))
        )
        ;; u32 result check
        (if (i32.ne (i32.load (global.get $RESULT_PTR)) (i32.const 0xf00d))
          (then (return (i32.const 7))))
        (return (i32.const 0))
      )
      ;; u8 result check: value then canaries at +1..+4 must be intact
      (if (i32.ne (i32.load8_u (global.get $RESULT_PTR)) (i32.const 0x5a))
        (then (return (i32.const 8))))
      (if (i32.ne (i32.load8_u (i32.add (global.get $RESULT_PTR) (i32.const 1))) (i32.const 0xaa))
        (then (return (i32.const 9))))
      (if (i32.ne (i32.load8_u (i32.add (global.get $RESULT_PTR) (i32.const 2))) (i32.const 0xaa))
        (then (return (i32.const 9))))
      (if (i32.ne (i32.load8_u (i32.add (global.get $RESULT_PTR) (i32.const 3))) (i32.const 0xaa))
        (then (return (i32.const 9))))
      (i32.const 0)
    )

    ;; Shared post-call handling: interpret the packed status. Returns the
    ;; callback code to give the runtime (task.return called on completion).
    (func $handle-status (param $ret i32) (result i32)
      (local $status i32) (local $code i32)
      (local.set $status (i32.and (local.get $ret) (i32.const 0xf)))

      ;; Eager RETURNED: no handle may be exposed; results already written.
      (if (i32.eq (local.get $status) (i32.const 2))
        (then
          (if (i32.ne (i32.shr_u (local.get $ret) (i32.const 4)) (i32.const 0))
            (then
              (call $task.return (i32.const 2))
              (return (i32.const 0 (; EXIT ;)))))
          (local.set $code (call $verify-result))
          (call $task.return (local.get $code)) ;; 0 = eager OK
          (return (i32.const 0 (; EXIT ;)))))

      (if (i32.ne (local.get $status) (i32.const 1 (; STARTED ;)))
        (then
          (call $task.return (i32.add (i32.const 100) (local.get $status)))
          (return (i32.const 0 (; EXIT ;)))))

      (global.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))
      (if (i32.eqz (global.get $subtask))
        (then
          (call $task.return (i32.const 3))
          (return (i32.const 0 (; EXIT ;)))))

      (global.set $ws (call $waitable-set.new))
      (call $waitable.join (global.get $subtask) (global.get $ws))
      ;; callback code WAIT = 2, waitable set index in the high bits
      (i32.or (i32.const 2) (i32.shl (global.get $ws) (i32.const 4)))
    )

    ;; Shared event callback: validate SUBTASK/RETURNED, verify results,
    ;; clean up, and task.return (1 = event path OK).
    (func $shared-cb (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
      (local $code i32)
      (block
        (block
          (if (i32.ne (local.get $event_code) (i32.const 1 (; SUBTASK ;)))
            (then (local.set $code (i32.const 4)) (br 1)))
          (if (i32.ne (local.get $index) (global.get $subtask))
            (then (local.set $code (i32.const 5)) (br 1)))
          (if (i32.ne (local.get $payload) (i32.const 2 (; RETURNED ;)))
            (then (local.set $code (i32.const 6)) (br 1)))
          (call $subtask.drop (global.get $subtask))
          (call $waitable-set.drop (global.get $ws))
          (local.set $code (call $verify-result))
          (if (i32.eqz (local.get $code))
            (then (local.set $code (i32.const 1)))) ;; 1 = event path OK
        )
      )
      (call $task.return (local.get $code))
      (i32.const 0 (; EXIT ;))
    )

    ;; --- exports -----------------------------------------------------------
    (func $check-with-result (export "check-with-result") (result i32)
      (global.set $verify (i32.const 1))
      (call $plant-canaries)
      (call $handle-status (call $fast-with-result (global.get $RESULT_PTR)))
    )
    (func $check-with-result-cb (export "check-with-result-cb")
          (param i32 i32 i32) (result i32)
      (call $shared-cb (local.get 0) (local.get 1) (local.get 2))
    )

    (func $check-u8-result (export "check-u8-result") (result i32)
      (global.set $verify (i32.const 2))
      (call $plant-canaries)
      (call $handle-status (call $fast-with-u8-result (global.get $RESULT_PTR)))
    )
    (func $check-u8-result-cb (export "check-u8-result-cb")
          (param i32 i32 i32) (result i32)
      (call $shared-cb (local.get 0) (local.get 1) (local.get 2))
    )

    (func $check-no-result (export "check-no-result") (result i32)
      (global.set $verify (i32.const 0))
      (call $handle-status (call $fast-no-result))
    )
    (func $check-no-result-cb (export "check-no-result-cb")
          (param i32 i32 i32) (result i32)
      (call $shared-cb (local.get 0) (local.get 1) (local.get 2))
    )
  )

  (canon task.return (result u32) (core func $task.return))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.drop (core func $waitable-set.drop))
  (canon lower (func $fast-no-result) async (memory $memory "mem") (core func $fast-no-result'))
  (canon lower (func $fast-with-result) async (memory $memory "mem") (core func $fast-with-result'))
  (canon lower (func $fast-with-u8-result) async (memory $memory "mem") (core func $fast-with-u8-result'))

  (core instance $core (instantiate $Core (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "task.return" (func $task.return))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.drop" (func $waitable-set.drop))
    (export "fast-no-result" (func $fast-no-result'))
    (export "fast-with-result" (func $fast-with-result'))
    (export "fast-with-u8-result" (func $fast-with-u8-result'))
  ))))

  (func (export "check-with-result") async (result u32) (canon lift
    (core func $core "check-with-result")
    async (callback (func $core "check-with-result-cb"))
  ))
  (func (export "check-u8-result") async (result u32) (canon lift
    (core func $core "check-u8-result")
    async (callback (func $core "check-u8-result-cb"))
  ))
  (func (export "check-no-result") async (result u32) (canon lift
    (core func $core "check-no-result")
    async (callback (func $core "check-no-result-cb"))
  ))
)
