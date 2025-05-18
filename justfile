build-exe:
    zig build-exe -femit-bin=zig-out/tlzum -O ReleaseFast -fstrip -fsingle-threaded -fomit-frame-pointer -flto --name tlzum -static src/main.zig
