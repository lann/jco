;; Regression fixture for async-lowered host import return-status handling.
;;
;; See STALE-SUBTASK-EVENT-GUEST-TRAP: an async-lowered host import that
;; resolves before the lowered call returns must NOT take the eager
;; "RETURNED, no subtask handle" path when the import has a result pointer.
;; Doing so lets the guest release its params/results storage earlier than
;; the rest of the runtime machinery assumes, corrupting guest state under
;; concurrent in-flight imports. Result-bearing imports must instead report
;; STARTED with a subtask handle and deliver RETURNED through the standard
;; waitable-set event path (with the result written to the out-pointer no
;; later than event delivery).
;;
;; Exports (both callback-ABI async lifts) drive one import call each and
;; report a diagnostic code via task.return:
;;
;;   check-with-result: 0   = STARTED + event-path lifecycle completed OK
;;                      2   = eager RETURNED observed (the regression)
;;                      3   = STARTED but subtask handle was 0
;;                      4-7 = event delivery/result checks failed (see code)
;;                      100+s = unexpected initial status s
;;
;;   check-no-result:   0   = eager RETURNED (no handle exposed)
;;                      1   = STARTED + event-path lifecycle completed OK
;;                            (allowed: eagerness is host timing dependent)
;;                      10  = eager RETURNED but with a nonzero handle
;;                      4-6 = event delivery checks failed
;;                      100+s = unexpected initial status s
;;
;; Status codes (low 4 bits of the lowered call's packed return):
;;   0 = STARTING, 1 = STARTED, 2 = RETURNED
;; Event codes: 1 = SUBTASK; event payload 2 = RETURNED.
(component
  ;; Host-provided async imports
  (import "fast-no-result" (func $fast-no-result async))
  (import "fast-with-result" (func $fast-with-result async (result u32)))

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

    ;; out-pointer for fast-with-result's u32 result
    (global $RESULT_PTR i32 (i32.const 16))

    (global $subtask (mut i32) (i32.const 0))
    (global $ws (mut i32) (i32.const 0))
    ;; result code to task.return for the no-result check's event path
    (global $ok-code (mut i32) (i32.const 0))

    ;; Shared: join $subtask into a fresh waitable set and return the packed
    ;; WAIT callback code for it.
    (func $wait-on-subtask (result i32)
      (global.set $ws (call $waitable-set.new))
      (call $waitable.join (global.get $subtask) (global.get $ws))
      ;; callback code WAIT = 2, waitable set index in the high bits
      (i32.or (i32.const 2) (i32.shl (global.get $ws) (i32.const 4)))
    )

    ;; Shared: validate a SUBTASK/RETURNED event for $subtask, then clean up.
    ;; Returns 0 on success, or a diagnostic code (4-6).
    (func $consume-returned-event (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
      (if (i32.ne (local.get $event_code) (i32.const 1 (; SUBTASK ;)))
        (then (return (i32.const 4))))
      (if (i32.ne (local.get $index) (global.get $subtask))
        (then (return (i32.const 5))))
      (if (i32.ne (local.get $payload) (i32.const 2 (; RETURNED ;)))
        (then (return (i32.const 6))))
      (call $subtask.drop (global.get $subtask))
      (call $waitable-set.drop (global.get $ws))
      (i32.const 0)
    )

    ;; --- check-with-result -------------------------------------------------
    (func $check-with-result (export "check-with-result") (result i32)
      (local $ret i32) (local $status i32)

      (local.set $ret (call $fast-with-result (global.get $RESULT_PTR)))
      (local.set $status (i32.and (local.get $ret) (i32.const 0xf)))

      ;; The regression: a result-bearing import must not return eagerly.
      (if (i32.eq (local.get $status) (i32.const 2 (; RETURNED ;)))
        (then
          (call $task.return (i32.const 2))
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

      (call $wait-on-subtask)
    )

    (func $check-with-result-cb (export "check-with-result-cb")
          (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
      (local $code i32)
      (local.set $code
        (call $consume-returned-event (local.get $event_code) (local.get $index) (local.get $payload)))
      (if (i32.eqz (local.get $code))
        (then
          ;; The result must be written by the time the event is delivered.
          (if (i32.ne (i32.load (global.get $RESULT_PTR)) (i32.const 0xf00d))
            (then (local.set $code (i32.const 7))))))
      (call $task.return (local.get $code))
      (i32.const 0 (; EXIT ;))
    )

    ;; --- check-no-result ---------------------------------------------------
    (func $check-no-result (export "check-no-result") (result i32)
      (local $ret i32) (local $status i32)

      (local.set $ret (call $fast-no-result))
      (local.set $status (i32.and (local.get $ret) (i32.const 0xf)))

      ;; Eager return: no subtask handle may be exposed.
      (if (i32.eq (local.get $status) (i32.const 2 (; RETURNED ;)))
        (then
          (if (i32.ne (i32.shr_u (local.get $ret) (i32.const 4)) (i32.const 0))
            (then
              (call $task.return (i32.const 10))
              (return (i32.const 0 (; EXIT ;)))))
          (call $task.return (i32.const 0))
          (return (i32.const 0 (; EXIT ;)))))

      (if (i32.ne (local.get $status) (i32.const 1 (; STARTED ;)))
        (then
          (call $task.return (i32.add (i32.const 100) (local.get $status)))
          (return (i32.const 0 (; EXIT ;)))))

      (global.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))
      (global.set $ok-code (i32.const 1))
      (call $wait-on-subtask)
    )

    (func $check-no-result-cb (export "check-no-result-cb")
          (param $event_code i32) (param $index i32) (param $payload i32) (result i32)
      (local $code i32)
      (local.set $code
        (call $consume-returned-event (local.get $event_code) (local.get $index) (local.get $payload)))
      (if (i32.eqz (local.get $code))
        (then (local.set $code (global.get $ok-code))))
      (call $task.return (local.get $code))
      (i32.const 0 (; EXIT ;))
    )
  )

  (canon task.return (result u32) (core func $task.return))
  (canon subtask.drop (core func $subtask.drop))
  (canon waitable.join (core func $waitable.join))
  (canon waitable-set.new (core func $waitable-set.new))
  (canon waitable-set.drop (core func $waitable-set.drop))
  (canon lower (func $fast-no-result) async (memory $memory "mem") (core func $fast-no-result'))
  (canon lower (func $fast-with-result) async (memory $memory "mem") (core func $fast-with-result'))

  (core instance $core (instantiate $Core (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "task.return" (func $task.return))
    (export "subtask.drop" (func $subtask.drop))
    (export "waitable.join" (func $waitable.join))
    (export "waitable-set.new" (func $waitable-set.new))
    (export "waitable-set.drop" (func $waitable-set.drop))
    (export "fast-no-result" (func $fast-no-result'))
    (export "fast-with-result" (func $fast-with-result'))
  ))))

  (func (export "check-with-result") async (result u32) (canon lift
    (core func $core "check-with-result")
    async (callback (func $core "check-with-result-cb"))
  ))
  (func (export "check-no-result") async (result u32) (canon lift
    (core func $core "check-no-result")
    async (callback (func $core "check-no-result-cb"))
  ))
)
