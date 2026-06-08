# lua-resty-tcp-drop

Note: this README was generated with assistance from AI and should be reviewed against the source code and your deployment environment.

Drop an OpenResty request connection silently by enabling Linux `TCP_REPAIR` on the current client socket, then returning nginx status `444`.

This module is intentionally small and Linux-specific. It uses LuaJIT FFI to read the active nginx request connection and call privileged Linux socket/capability APIs.

## Requirements

- Linux
- 64-bit LuaJIT/OpenResty
- nginx version `1.13.0` through `1.31.1`
- OpenResty `resty.core`
- OpenResty HTTP or stream subsystem
- nginx master process started as root when using the capability helper APIs
- `CAP_NET_ADMIN` available to the worker before calling `drop()`

## API

### `tcp_drop.try_inherit_caps(force_init?, all_caps?)`

Call from `init_by_lua_block`.

This prepares capability retention before nginx changes worker identity.

- `force_init`: bypasses the once-only check when set to `true`. The root check always applies.
- `all_caps`: when set to `true`, uses `SECBIT_NO_SETUID_FIXUP | SECBIT_KEEP_CAPS`; otherwise uses `SECBIT_KEEP_CAPS`. This option is dangerous because it can preserve more privileges across nginx's root-to-worker UID transition than this module needs.

Returns `true` on success, or `nil, err`.

### `tcp_drop.try_acquire_cap_net_admin()`

Call from `init_worker_by_lua_block`.

This is the second phase of capability setup. It raises `CAP_NET_ADMIN` into the worker's effective capability set so later `TCP_REPAIR` calls can succeed. After this succeeds, each nginx worker running it has effective `CAP_NET_ADMIN`.

Returns `true` on success, or `nil, err`.

### `tcp_drop.drop()`

Alias: `tcp_drop.silent_drop()`.

Call from an HTTP request phase or stream preread/content phase. It gets the current client connection fd, tries to enable `TCP_REPAIR`, and exits with nginx status `444`. If `TCP_REPAIR` fails (for example, `CAP_NET_ADMIN` is not available), the failure is logged at `WARN` level and nginx still handles the close through status `444`.

### `tcp_drop.get_conn_fd()`

Returns the current HTTP request or stream session connection fd, or `nil, err`.

## Example

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

For stream usage, call the same init helpers at the `stream` block level and call `drop()` from a stream Lua phase such as `preread_by_lua_block`:

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

## Security Notes

`TCP_REPAIR` requires `CAP_NET_ADMIN`. The recommended setup is two-phase:

1. `init_by_lua_block`: retain capabilities across nginx's worker UID transition.
2. `init_worker_by_lua_block`: raise `CAP_NET_ADMIN` into the worker's effective capability set.

Avoid passing `all_caps = true` unless your deployment specifically needs it and you have reviewed the resulting process privileges. It is a dangerous option because it can retain capabilities unrelated to `TCP_REPAIR`.

`try_acquire_cap_net_admin()` intentionally gives each nginx worker effective `CAP_NET_ADMIN`. That capability is powerful; restrict the nginx worker code path, loaded Lua modules, and third-party nginx modules accordingly.

## Development

There is no full integration test harness in this repository. Minimal syntax checks can be run with:

```sh
luajit -e "assert(loadfile('lib/resty/tcp_drop.lua'))"
luajit -e "assert(loadfile('lib/resty/proc_caps.lua'))"
```

Behavioral verification requires Linux/OpenResty because the module depends on nginx request internals and Linux socket capability APIs.
