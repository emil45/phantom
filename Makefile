.PHONY: daemon daemon-release ios clean release

daemon:
	cd daemon && cargo build

daemon-release:
	cd daemon && cargo build --release

daemon-run:
	cd daemon && cargo run

release:
	./scripts/build-release.sh

clean:
	cd daemon && cargo clean
	rm -rf build
