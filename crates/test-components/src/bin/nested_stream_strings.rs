mod bindings {
    use super::Component;
    wit_bindgen::generate!({
        world: "nested-stream-strings",
    });
    export!(Component);
}

use wit_bindgen::StreamReader;

use bindings::Entry;

struct Component;

impl bindings::Guest for Component {
    async fn read_entries(mut entries: StreamReader<Entry>) -> Vec<(String, Vec<u8>)> {
        let mut vals = Vec::new();
        while let Some(entry) = entries.next().await {
            let contents = read_async_values(entry.contents).await;
            vals.push((entry.name, contents));
        }
        vals
    }
}

async fn read_async_values<T>(mut rx: StreamReader<T>) -> Vec<T> {
    let mut vals = Vec::new();
    while let Some(v) = rx.next().await {
        vals.push(v);
    }
    vals
}

// Stub only to ensure this works as a binary
fn main() {}
