# lua-resty-tcp-drop

说明：本文档由 AI 辅助生成，请结合源代码和你的实际部署环境进行审核。

这个 OpenResty 模块会尝试在当前客户端 socket 上启用 Linux `TCP_REPAIR`，然后返回 nginx 状态码 `444`，用于静默丢弃连接。

本模块刻意保持小而专用，并且只面向 Linux。它使用 LuaJIT FFI 读取当前 nginx 请求/会话的连接信息，并调用需要特权的 Linux socket/capability API。

## 运行要求

- Linux
- 64 位 LuaJIT/OpenResty
- nginx 版本 `1.13.0` 到 `1.31.1`
- OpenResty `resty.core`
- OpenResty HTTP 或 stream 子系统
- 使用 capability 辅助 API 时，nginx master 进程需要以 root 启动
- worker 在调用 `drop()` 前需要具备 `CAP_NET_ADMIN`

## API

### `tcp_drop.try_inherit_caps(force_init?, all_caps?)`

在 `init_by_lua_block` 中调用。

此函数在 nginx 切换 worker 身份前准备 capability 保留。

- `force_init`：设为 `true` 时跳过只执行一次的检查。root 检查始终生效。
- `all_caps`：设为 `true` 时使用 `SECBIT_NO_SETUID_FIXUP | SECBIT_KEEP_CAPS`；否则使用 `SECBIT_KEEP_CAPS`。这个选项是危险的，因为它可能在 nginx 从 root 切换到 worker UID 时保留超过本模块所需的权限。

成功时返回 `true`，失败时返回 `nil, err`。

### `tcp_drop.try_acquire_cap_net_admin()`

在 `init_worker_by_lua_block` 中调用。

这是 capability 设置的第二阶段。它会把 `CAP_NET_ADMIN` 提升到 worker 的 effective capability set 中，使后续 `TCP_REPAIR` 调用可以成功。调用成功后，每个执行它的 nginx worker 都拥有 effective `CAP_NET_ADMIN`。

成功时返回 `true`，失败时返回 `nil, err`。

### `tcp_drop.drop()`

别名：`tcp_drop.silent_drop()`。

在 HTTP 请求阶段或 stream 的 preread/content 阶段调用。它会获取当前客户端连接 fd，尝试启用 `TCP_REPAIR`，然后以 nginx 状态码 `444` 退出。如果 `TCP_REPAIR` 失败，例如没有 `CAP_NET_ADMIN`，模块会以 `WARN` 级别记录失败信息，并仍然交由 nginx 通过状态码 `444` 处理关闭。

### `tcp_drop.get_conn_fd()`

返回当前 HTTP 请求或 stream 会话的连接 fd；失败时返回 `nil, err`。

## 示例

```nginx
lua_package_path "/path/to/lua-resty-tcp-drop/lib/?.lua;;";

init_by_lua_block {
    local tcp_drop = require "resty.tcp_drop"
    local ok, err = tcp_drop.try_inherit_caps()
    if not ok and err ~= "initialized" then
        ngx.log(ngx.WARN, "tcp_drop init failed: ", err)
    end
}

init_worker_by_lua_block {
    local tcp_drop = require "resty.tcp_drop"
    local ok, err = tcp_drop.try_acquire_cap_net_admin()
    if not ok then
        ngx.log(ngx.WARN, "tcp_drop CAP_NET_ADMIN setup failed: ", err)
    end
}

server {
    listen 8080;

    location /blocked {
        access_by_lua_block {
            require("resty.tcp_drop").drop()
        }
    }
}
```

stream 用法类似：在 `stream` 块级别调用相同的 init 辅助函数，并在 `preread_by_lua_block` 等 stream Lua 阶段调用 `drop()`：

```nginx
stream {
    lua_package_path "/path/to/lua-resty-tcp-drop/lib/?.lua;;";

    init_by_lua_block {
        require("resty.tcp_drop").try_inherit_caps()
    }

    init_worker_by_lua_block {
        require("resty.tcp_drop").try_acquire_cap_net_admin()
    }

    server {
        listen 9000;

        preread_by_lua_block {
            require("resty.tcp_drop").drop()
        }

        proxy_pass 127.0.0.1:9001;
    }
}
```

## 安全说明

`TCP_REPAIR` 需要 `CAP_NET_ADMIN`。推荐使用两阶段设置：

1. `init_by_lua_block`：在 nginx worker UID 切换前保留 capability。
2. `init_worker_by_lua_block`：把 `CAP_NET_ADMIN` 提升到 worker 的 effective capability set。

除非部署确实需要，并且你已经审查过最终进程权限，否则不要传入 `all_caps = true`。这是一个危险选项，因为它可能保留与 `TCP_REPAIR` 无关的 capability。

`try_acquire_cap_net_admin()` 会有意让每个 nginx worker 拥有 effective `CAP_NET_ADMIN`。这个 capability 权限很强，请相应限制 worker 中运行的 Lua 代码路径、加载的 Lua 模块以及第三方 nginx 模块。

## 开发

本仓库没有完整的集成测试框架。可以运行以下最小语法检查：

```sh
luajit -e "assert(loadfile('lib/resty/tcp_drop.lua'))"
luajit -e "assert(loadfile('lib/resty/proc_caps.lua'))"
```

行为验证需要 Linux/OpenResty 环境，因为模块依赖 nginx 请求内部结构和 Linux socket/capability API。
