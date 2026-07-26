import { join } from 'node:path';

import { suite, test, assert } from 'vitest';

import { setupAsyncTest } from '../helpers.js';
import { P3_COMPONENT_FIXTURES_DIR } from '../common.js';

// Regression tests for the return status of async-lowered host imports that
// resolve before the lowered call returns ("fast" imports).
//
// An async-lowered import *may* return eagerly with status RETURNED (2) and
// no subtask handle, per the Component Model async import ABI. However, for
// result-bearing imports the eager return has been observed to corrupt guest
// (e.g. Rust wit-bindgen) state under concurrent in-flight imports: the guest
// releases its params/results storage as soon as it observes the eager
// RETURNED, earlier than the event-path lifecycle the rest of the generated
// runtime machinery assumes. Result-bearing imports must therefore report
// STARTED with a subtask handle and deliver RETURNED through the standard
// waitable-set event path.
//
// The fixture component checks the packed status codes from raw core wasm and
// reports a diagnostic code via task.return; see component.wat for the code
// legend.
suite('Async host import eager-return status (WASI P3)', () => {
    const componentName = 'async-import-eager-return';
    const componentPath = join(P3_COMPONENT_FIXTURES_DIR, componentName, 'component.wasm');

    test('result-bearing fast import takes the event path (STARTED + SUBTASK/RETURNED event)', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            component: {
                name: componentName,
                path: componentPath,
                imports: {
                    'fast-no-result': { default: async () => {} },
                    'fast-with-result': { default: async () => 0xf00d },
                },
            },
        });

        const code = await instance.checkWithResult();
        assert.notStrictEqual(
            code,
            2,
            'regression: result-bearing fast import returned eagerly (RETURNED with no subtask handle)',
        );
        assert.strictEqual(
            code,
            0,
            `guest-side event-path lifecycle check failed with diagnostic code [${code}] (see component.wat)`,
        );

        await cleanup();
    });

    test('result-less fast import may return eagerly, and never exposes a handle when it does', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            component: {
                name: componentName,
                path: componentPath,
                imports: {
                    'fast-no-result': { default: async () => {} },
                    'fast-with-result': { default: async () => 0xf00d },
                },
            },
        });

        const code = await instance.checkNoResult();
        // 0 = eager RETURNED (expected for a fast import), 1 = event path
        // (allowed: eagerness depends on host timing). Anything else is a
        // guest-side check failure; see component.wat for the code legend.
        assert.include(
            [0, 1],
            code,
            `guest-side lifecycle check failed with diagnostic code [${code}] (see component.wat)`,
        );

        await cleanup();
    });
});
