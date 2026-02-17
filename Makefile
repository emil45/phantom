.PHONY: daemon daemon-release ios clean

daemon:
	cd daemon && cargo build

daemon-release:
	cd daemon && cargo build --release

daemon-run:
	cd daemon && cargo run

clean:
	cd daemon && cargo clean
