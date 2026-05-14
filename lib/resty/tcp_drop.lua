---
--- Nginx's Connection Related interop.
--- Copyright (c) Appla <bhg@live.it>
---

local ffi = require 'ffi'
local C = ffi.C

local tonumber = tonumber
local sprintf = string.format

local ngx = ngx
local ngx_log = ngx.log
local ngx_version = ngx.config.nginx_version
local get_phase = ngx.get_phase
local get_request = require "resty.core.base".get_request
local proc_caps = require "resty.proc_caps"

local bit = require 'bit'
local band, bor = bit.band, bit.bor

-- constants
local LOG_WARN = ngx.WARN

-- variables
--- valid flags: 0x0010: module initialized, 0x0020: get_conn_fd fail logged, 0x0040: tcp_repair fail logged, 0x0080: CAP_NET_ADMIN acquired
local g_state = 0

local _M = {
    _VERSION = "1.0.0.260514"
}

ffi.cdef [[
    int setsockopt(int sockfd, int level, int optname, const void *optval, uint32_t optlen);
    char *strerror(int errnum);
    uint32_t getuid();
]]

do
    assert(jit and jit.os == 'Linux', "only support Linux with LuaJIT")
    assert(ffi.abi("64bit"), "only support 64-bit nginx/LuaJIT")
    -- Compatible with specific versions, currently targeted at 1.13.0 - 1.29.5
    if ngx_version < 1013000 or ngx_version > 1029005 then
        error("required nginx version greater than 1.13.0 AND less than 1.29.6 got " .. tostring(ngx_version))
    end
    if not pcall(ffi.typeof, "td_ngx_connection_t") then
        ffi.cdef [[
            typedef struct {
                int64_t      dummy_padding_1[3];
                int          fd;
             } td_ngx_connection_t;
        ]]
    end

    if not pcall(ffi.typeof, "td_ngx_lua_request_t") then
        if ngx.config.subsystem == "http" then
            ffi.cdef [[
                typedef struct {
                    uint32_t               signature;
                    td_ngx_connection_t    *connection;
                } td_ngx_lua_request_t;
            ]]
        elseif ngx.config.subsystem == "stream" then
            --- struct ngx_stream_lua_request_s
            ffi.cdef [[
                typedef struct {
                    td_ngx_connection_t    *connection;
                } td_ngx_lua_request_t;
            ]]
        else
            error("unsupported subsystem: " .. ngx.config.subsystem)
        end
    end
end

local get_connection
do
    local ffi_cast = ffi.cast
    local ngx_lua_request_ctp = ffi.typeof("td_ngx_lua_request_t *")

    function get_connection()
        local r = get_request()
        if not r then
            return nil, "no request found"
        end
        local tmp_r = ffi_cast(ngx_lua_request_ctp, r)

        local conn = tmp_r.connection
        if conn == nil then
            return nil, "no connection found"
        end
        return conn
    end
end

local function get_conn_fd()
    local conn, err = get_connection()
    if conn then
        return tonumber(conn.fd)
    end
    return nil, err
end

_M.get_conn_fd = get_conn_fd

local set_tcp_repair
do
    local ffi_errno = ffi.errno
    local ffi_string = ffi.string

    local int_ptr = ffi.new("int[1]", 1)
    local INT_SIZE = ffi.sizeof("int")

    local SOL_TCP = 6
    local TCP_REPAIR = 19

    function set_tcp_repair(fd)
        local rc = C.setsockopt(fd, SOL_TCP, TCP_REPAIR, int_ptr, INT_SIZE)

        if rc ~= 0 then
            local errno = ffi_errno()
            local err_msg = sprintf("TCP_REPAIR failed: %s (errno=%d) -- need CAP_NET_ADMIN?", ffi_string(C.strerror(errno)), errno)
            return false, err_msg
        end

        return true
    end
end

do
    local function inherit_caps_pub(force_init, all_caps)
        if get_phase() ~= "init" then
            return nil, 'init phase expected'
        end
        if force_init ~= true and band(g_state, 0x0010) ~= 0 then
            return nil, "initialized"
        end

        if C.getuid() ~= 0 then
            return nil, 'root user expected'
        end

        local rc, err
        if all_caps then
            rc, err = proc_caps.inherit_all_caps()
        else
            rc, err = proc_caps.inherit_caps()
        end
        if rc then
            g_state = bor(g_state, 0x0010)
        end
        return rc, err
    end

    -- Raise CAP_NET_ADMIN into the effective set in init_worker phase.
    --- @return boolean success
    function _M.try_acquire_cap_net_admin()
        if get_phase() ~= "init_worker" then
            return nil, 'init_worker phase expected'
        end
        local rc, err = proc_caps.raise_net_admin()
        if not rc and err then
            ngx_log(LOG_WARN, "acquire_cap_net_admin failed: ", err)
        end
        return rc, err
    end

    -- Inherit caps in init phase.
    --- @param force_init boolean force inherit capabilities
    --- @param all_caps boolean inherit all capabilities
    --- @return boolean success
    function _M.try_inherit_caps(force_init, all_caps)
        local rc, err = inherit_caps_pub(force_init, all_caps)
        if not rc and err ~= "initialized" then
            ngx_log(LOG_WARN, "ngx_conn init: ", err)
        end
        return rc, err
    end
end

do
    local ngx_exit = ngx.exit

    local function silent_drop_connection()
        local fd, err = get_conn_fd()
        if fd then
            local rc, repair_err = set_tcp_repair(fd)
            if not rc and repair_err then
                --g_state = bor(g_state, 0x0040)
                ngx_log(LOG_WARN, "silent_drop failed: ", repair_err)
            end
        elseif err and band(g_state, 0x0020) == 0 then
            g_state = bor(g_state, 0x0020)
            ngx_log(LOG_WARN, "get_conn_fd: ", err)
        end
        return ngx_exit(444)
    end

    _M.drop = silent_drop_connection
    _M.silent_drop = silent_drop_connection
end

return _M
