mod bindings {
    use super::Component;
    wit_bindgen::generate!({
        world: "sync-to-async-caller",
        // Force the (WIT-async) compute import to be *sync-lowered*: the
        // binding blocks until the callee resolves, and the fused adapter
        // routes the call through PrepareCall + SyncStartCall
        // (see lann/jco#45).
        async: ["-import:jco:test-components/sync-lower-compute#compute"],
    });
    export!(Component);
}

use bindings::exports::jco::test_components::sync_lower_runner::Guest;
use bindings::jco::test_components::sync_lower_compute;

struct Component;

impl Guest for Component {
    async fn run_compute(x: u32) -> u32 {
        // Blocking (sync-lowered) call to the composed callee's async-lifted
        // export.
        sync_lower_compute::compute(x)
    }
}

// Stub only to ensure this works as a binary
fn main() {}
