"""在 Modal 上编一份**只含本模型所需算子**的 ONNX Runtime Android AAR。

    modal run tools/build_ort_aar.py

背景:全量 onnxruntime-android 的 arm64 libonnxruntime.so 有 18.35MB(实测),
官方唯一的预编译精简包 onnxruntime-mobile 冻结在 1.18.0 且与插件的 Java API
不兼容(flutter_onnxruntime 1.8.4 钉的是 1.23.0)。所以只能自己编:版本对齐
1.23.0 保证插件能编译,算子按本模型裁剪拿回体积,而且**算子表由我们指定**,
int8 需要的 ConvInteger / DynamicQuantizeLinear 可以包含进去 —— 这正是那个
冻结包做不到的。

在 Linux 上编而不是本机 Windows:这是 ORT Android 构建最顺的路径,而且能开
多核并行,不占本机一两个小时。
"""

import pathlib

import modal

ORT_VERSION = "v1.23.0"
NDK_VERSION = "27.2.12479018"

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install(
        "git", "wget", "unzip", "build-essential", "openjdk-17-jdk",
        "libncurses6", "zlib1g-dev", "ca-certificates",
    )
    .pip_install("cmake", "ninja", "packaging", "numpy", "flatbuffers", "protobuf", "psutil", "setuptools", "wheel")
    # Android SDK cmdline-tools + platform/build-tools(打 AAR 要 gradle 用)
    .run_commands(
        "mkdir -p /android/cmdline-tools",
        "wget -q -O /tmp/cmdline.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip",
        "unzip -q /tmp/cmdline.zip -d /android/cmdline-tools && mv /android/cmdline-tools/cmdline-tools /android/cmdline-tools/latest",
        "yes | /android/cmdline-tools/latest/bin/sdkmanager --sdk_root=/android --licenses > /dev/null",
        "/android/cmdline-tools/latest/bin/sdkmanager --sdk_root=/android "
        "'platform-tools' 'platforms;android-34' 'build-tools;34.0.0' "
        f"'ndk;{NDK_VERSION}' > /dev/null",
    )
    # ORT 源码(子模块很多,用 shallow 省时间/空间)
    .run_commands(
        f"git clone --depth 1 --branch {ORT_VERSION} --recursive --shallow-submodules "
        "https://github.com/microsoft/onnxruntime.git /ort",
    )
    .env({
        "ANDROID_HOME": "/android",
        "ANDROID_SDK_ROOT": "/android",
        "ANDROID_NDK_HOME": f"/android/ndk/{NDK_VERSION}",
        "JAVA_HOME": "/usr/lib/jvm/java-17-openjdk-amd64",
    })
)

app = modal.App("censor-ort-build", image=image)
HERE = pathlib.Path(__file__).parent


@app.function(timeout=7200, cpu=16.0, memory=32768)
def build(ops_config: bytes) -> dict[str, bytes]:
    import glob
    import json
    import os
    import subprocess

    os.chdir("/ort")
    with open("/tmp/ops.config", "wb") as f:
        f.write(ops_config)

    # 官方那份 default_mobile_aar_build_settings.json 随 mobile 包一起在 1.23
    # 被删了,所以自己写一份。要点:
    #   * 只留 arm64-v8a —— 本 app 的 abiFilters 就只有它,编另外三个纯属
    #     把构建时间乘四
    #   * --minimal_build=extended —— 我们的 .ort 是 optimization_style=Runtime
    #     转的,运行时优化要靠 extended 档才能应用
    #   * 不要 --use_nnapi / --use_xnnpack:都是额外 EP,只跑 CPU 用不上,
    #     白占体积(MLAS 本身就在,ARM64 上的卷积不慢)
    settings = {
        "build_abis": ["arm64-v8a"],
        "android_min_sdk_version": 24,
        "android_target_sdk_version": 34,
        "build_params": [
            "--enable_lto",
            "--android",
            "--parallel",
            "--cmake_generator=Ninja",
            "--build_java",
            "--build_shared_lib",
            "--skip_tests",
            "--minimal_build=extended",
            "--disable_ml_ops",
            "--enable_reduced_operator_type_support",
            # Modal 容器里是 root,build.py 默认拒绝
            "--allow_running_as_root",
        ],
    }
    print("构建参数:", json.dumps(settings, indent=2))
    with open("/tmp/settings.json", "w") as f:
        json.dump(settings, f)

    # build_aar_package.py 把 `--use_vcpkg --use_vcpkg_ms_internal_asset_cache`
    # **硬编码**进构建命令,后者指向微软内网的资产缓存,外面根本够不着。
    # 摘掉这两个,依赖走已经 --recursive 克隆下来的子模块。
    script = "tools/ci_build/github/android/build_aar_package.py"
    src = open(script).read()
    patched = src.replace(
        '+ ["--config=" + build_config, "--use_vcpkg", "--use_vcpkg_ms_internal_asset_cache"]',
        '+ ["--config=" + build_config]',
    )
    if patched == src:
        print("⚠ vcpkg 参数没匹配上,脚本可能已改版")
    else:
        open(script, "w").write(patched)
        print("已摘掉 vcpkg 内网缓存参数")

    # 注意 build_settings_file 是**位置参数**,不是 --build_settings_file
    cmd = [
        "python3", "tools/ci_build/github/android/build_aar_package.py",
        "--build_dir", "/tmp/aarbuild",
        "--config", "MinSizeRel",
        "--android_sdk_path", "/android",
        "--android_ndk_path", f"/android/ndk/{NDK_VERSION}",
        "--include_ops_by_config", "/tmp/ops.config",
        "/tmp/settings.json",
    ]
    print("$", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout[-20000:], flush=True)
    if r.returncode != 0:
        print("STDERR:", r.stderr[-20000:], flush=True)

    aars = glob.glob("/tmp/aarbuild/**/*.aar", recursive=True)
    print("找到 AAR:", aars)
    if not aars:
        raise RuntimeError(
            "没有产出 AAR。日志尾部:\n" + (r.stderr[-6000:] or r.stdout[-6000:])
        )
    out: dict[str, bytes] = {}
    for a in aars:
        out[os.path.basename(a)] = open(a, "rb").read()
        # 顺带报一下里面的 .so 大小 —— 那才是我们要的数字
        z = subprocess.run(["unzip", "-l", a], capture_output=True, text=True)
        print(f"--- {a}\n{z.stdout}", flush=True)
    return out


@app.local_entrypoint()
def main():
    cfg = (HERE / "censor_ops.config").read_bytes()
    print(f"算子清单 {len(cfg)} B,开始构建(可能要 30–60 分钟)…")
    res = build.remote(cfg)
    dst = HERE / "ort_aar_out"
    dst.mkdir(exist_ok=True)
    for name, data in res.items():
        (dst / name).write_bytes(data)
        print(f"{len(data):>12}  {name}")
    print(f"\n产物写入 {dst}")
