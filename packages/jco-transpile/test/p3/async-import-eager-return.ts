import { join } from 'node:path';

import { suite, test, assert } from 'vitest';

import { setupAsyncTest } from '../helpers.js';
import { P3_COMPONENT_FIXTURES_DIR } from '../common.js';

// Regression tests for async-lowered host imports that resolve before the
// lowered call returns ("fast" imports), and for the width of 8-bit result
// lowerings.
//
// Per the Component Model async import ABI (canon_lower), a fast import may
// return eagerly with status RETURNED (2) and no subtask handle -- in which
// case its results must already be written -- or report STARTED (1) with a
// subtask handle and deliver RETURNED through the standard waitable-set event
// path. The fixture verifies whichever path is taken end-to-end from raw core
// wasm and reports a diagnostic code via task.return (0 = eager path OK,
// 1 = event path OK; see component.wat for the full code legend).
//
// The u8-result check additionally surrounds its 1-byte result slot with
// canary bytes: the metadata-driven `_lowerFlatU8`/`_lowerFlatS8`/
// `_lowerFlatBool` intrinsics used to write a full 32 bits per 8-bit value,
// spilling up to 3 bytes past result slots and list allocations and poisoning
// adjacent dlmalloc chunk metadata in the guest -- the root cause of
// STALE-SUBTASK-EVENT-GUEST-TRAP (delayed heap corruption: freed-funcref
// traps at waker dispatch, dealloc aborts, and stale-looking subtask events).
suite('Async host import fast-return handling (WASI P3)', () => {
    const componentName = 'async-import-eager-return';
    const componentPath = join(P3_COMPONENT_FIXTURES_DIR, componentName, 'component.wasm');

    const imports = {
        'fast-no-result': { default: async () => {} },
        'fast-with-result': { default: async () => 0xf00d },
        'fast-with-u8-result': { default: async () => 0x5a },
    };

    test('u8 result lowering writes exactly one byte (canary check)', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            component: { name: componentName, path: componentPath, imports },
        });

        const code = await instance.checkU8Result();
        assert.notStrictEqual(
            code,
            9,
            'regression: 8-bit result lowering clobbered canary bytes adjacent to the result slot',
        );
        assert.include(
            [0, 1],
            code,
            `guest-side u8-result check failed with diagnostic code [${code}] (see component.wat)`,
        );

        await cleanup();
    });

    test('fast result-bearing import completes with results intact (eager or event path)', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            component: { name: componentName, path: componentPath, imports },
        });

        const code = await instance.checkWithResult();
        assert.include(
            [0, 1],
            code,
            `guest-side lifecycle check failed with diagnostic code [${code}] (see component.wat)`,
        );

        await cleanup();
    });

    test('fast result-less import completes, exposing no handle when eager', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            component: { name: componentName, path: componentPath, imports },
        });

        const code = await instance.checkNoResult();
        assert.include(
            [0, 1],
            code,
            `guest-side lifecycle check failed with diagnostic code [${code}] (see component.wat)`,
        );

        await cleanup();
    });
});
