use libbpf_cargo::SkeletonBuilder;
use std::{env, path::PathBuf};

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("egress_acct.skel.rs");
    SkeletonBuilder::new()
        // The eBPF C program lives one dir up (shared with the C-userspace history of 4.4).
        .source("../egress_acct.bpf.c")
        .clang_args(["-I/usr/include/x86_64-linux-gnu", "-D__TARGET_ARCH_x86"])
        .build_and_generate(&out)
        .unwrap();
    println!("cargo:rerun-if-changed=../egress_acct.bpf.c");
}
