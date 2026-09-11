# third_party 开源依赖

本目录 vendoring 成熟开源库，避免手写 JSON/HTTP 解析。

| 库 | 来源 | 许可证 | 用途 |
|---|---|---|---|
| [cJSON](https://github.com/DaveGamble/cJSON) | DaveGamble/cJSON v1.7.19 | MIT | JSON 读写（preferences / secure storage） |
| [libcurl](https://curl.se/libcurl/) | curl 8.x headers + OHOS 预编译 `libcurl.so` | curl license | C++ HTTP/HTTPS GET/POST（`http_client.cpp`） |

## cJSON

```bash
curl -o third_party/cjson/cJSON.c https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.c
curl -o third_party/cjson/cJSON.h https://raw.githubusercontent.com/DaveGamble/cJSON/master/cJSON.h
```

## libcurl

- **头文件**：`third_party/curl/include/`（与 curl 8.12.1 同步）
- **动态库**：`ohos/entry/libs/arm64-v8a/libcurl.so`（来自 [HarmonyOS_Samples/faqsnippets](https://gitee.com/HarmonyOS_Samples/faqsnippets) Ndk/Curl_Request 示例）

### 自行交叉编译（可选）

参考 OpenHarmony 三方库迁移指南：  
https://gitee.com/openharmony-sig/tpc_c_cplusplus

```bash
# 示例：OHOS SDK + CMake 交叉编译 curl
cmake -DCMAKE_TOOLCHAIN_FILE=$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake \
      -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared .. -G Ninja
cmake --build .
# 产物 libcurl.so 放入 ohos/entry/libs/arm64-v8a/
```

CMakeLists 已配置：

```cmake
target_link_libraries(entry PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libcurl.so)
```
