build-exe:
    zig build-exe -femit-bin=zig-out/tlzum \
        --name tlzum \
        -O ReleaseFast \
        -fstrip \
        -fsingle-threaded \
        -fomit-frame-pointer \
        -flto \
        -static \
        src/main.zig

preview-readme:
    pandoc --from=markdown --to=html --standalone=true --output=zig-out/readme.html README.md
    firefox zig-out/readme.html

benchmark:
    hyperfine --warmup=10 --shell=none ../tlsum/target/release/tlsum ./zig-out/tlzum
