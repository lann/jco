import { join } from 'node:path';
import { ReadableStream } from 'node:stream/web';

import { suite, test, assert } from 'vitest';

import { WASIShim } from '@bytecodealliance/preview2-shim/instantiation';

import { setupAsyncTest } from '../helpers.js';
import { AsyncFunction, LOCAL_TEST_COMPONENTS_DIR, createReadableStreamFromValues } from '../common.js';

// Regression coverage for lowering `string`s carried inside async value
// payloads (e.g. an `entry.name` in a `stream<entry>`): flat string lowering
// calls the `Utf8Encode` string intrinsic (`_utf8AllocateAndEncode`), whose
// definition must be emitted alongside the flat string lowering helper.
// Without it, the resulting `ReferenceError` is swallowed by the stream-write
// machinery and the nested-stream read looks like a deadlock.
suite('strings lowered inside nested stream payloads', () => {
    test('stream of records carrying a string and a nested stream', async () => {
        const { instance, cleanup } = await setupAsyncTest({
            asyncMode: 'jspi',
            component: {
                path: join(LOCAL_TEST_COMPONENTS_DIR, 'nested-stream-strings.wasm'),
                imports: {
                    ...new WASIShim().getImportObject(),
                },
            },
        });

        try {
            assert.instanceOf(instance.readEntries, AsyncFunction);

            const entries = [
                { name: 'hello.txt', contents: [104, 105] },
                { name: 'empty.txt', contents: [] },
                { name: 'data.bin', contents: [0, 127, 255] },
            ];
            const entryStream = createReadableStreamFromValues(
                entries.map(({ name, contents }) => ({
                    name,
                    contents: createReadableStreamFromValues(contents),
                })),
            );

            const returned = await Promise.race([
                instance.readEntries(entryStream),
                new Promise((_, reject) => setTimeout(() => reject(new Error('nested stream read timed out')), 5_000)),
            ]);
            assert.deepEqual(
                returned,
                entries.map(({ name, contents }) => [name, new Uint8Array(contents)]),
            );
        } finally {
            await cleanup();
        }
    });
});
