allprojects {
    repositories {
        // 自编精简版 ONNX Runtime,坐标与官方包同名 —— **必须排在最前**,
        // 否则会先从镜像拉到 19.3MB 的官方全量包。详见文件末尾的说明。
        maven(url = uri("${rootProject.projectDir}/ort-local-repo"))
        // 国内镜像优先:dl.google.com / repo.maven.apache.org 在本机不可达
        maven(url = "https://maven.aliyun.com/repository/google")
        maven(url = "https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // 插件模块(photo_manager 等)Java/Kotlin 编译目标不一致会被判错,统一对齐 app 的 17
    tasks.withType(JavaCompile::class.java).configureEach {
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
    }
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ONNX Runtime 换成**自编的精简版**:`android/ort-local-repo/` 下那个 AAR。
//
// 官方预编译的全量包 arm64 那份 libonnxruntime.so 一个人就 18.35MB(实测:
// 不带它 28.1MB,带它 46.5MB)。自编版按本模型的算子表裁剪后只有 **2.86MB**,
// 小 6.5 倍 —— 也比官方那个精简包(3.56MB)更小,因为算子是按这一个模型裁的。
//
// 为什么不用官方预编译的精简包(2026-09-08 试过,别重复踩):
//  1. onnxruntime-mobile **冻结在 1.18.0** 且已弃用;
//  2. flutter_onnxruntime 1.8.4 的 Kotlin 按新版 ORT Java API 写,编到
//     1.18.0 直接挂(`OnnxTensor.createTensor` 重载签名对不上);
//  3. 而且它的算子表里没有 int8 要的 ConvInteger。
// 自编版编的是 **1.23.0**(插件钉的就是这个),三个问题一起解决。
//
// 重新构建:`modal run tools/build_ort_aar.py`,完整流程见 tools/README.md。
// 只有换模型(算子表变了)或主动升 flutter_onnxruntime 时才需要重编 ——
// 插件迄今只跳过两次 ORT 大版本(1.21 → 1.22 → 1.23),不是持续负担。
//
// ⚠ 精简构建**只吃 .ort 格式**模型,不认 .onnx(见 assets/models 的说明)。
//
// 接入方式:`android/ort-local-repo/` 是个标准 Maven 仓库布局,坐标与官方包
// 完全一致(com.microsoft.onnxruntime:onnxruntime-android:1.23.0)。把它排在
// repositories 最前面,插件声明的那条依赖就自然解析到自编版 —— 不需要
// dependencySubstitution,也不需要为 AAR 建子模块。

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
