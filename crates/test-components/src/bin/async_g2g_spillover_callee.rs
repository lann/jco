mod bindings {
    use super::Component;
    wit_bindgen::generate!({
        world: "async-g2g-spillover-callee",
    });
    export!(Component);
}

use bindings::exports::jco::test_components::spillover_g2g_api::Guest;

struct Component;

impl Guest for Component {
    async fn add5(p1: u32, p2: u32, p3: u32, p4: u32, p5: u32) -> u32 {
        p1 + p2 + p3 + p4 + p5
    }

    async fn concat3(a: String, b: String, c: u8) -> String {
        format!("{a}{b}{c}")
    }
}

// Stub only to ensure this works as a binary
fn main() {}
