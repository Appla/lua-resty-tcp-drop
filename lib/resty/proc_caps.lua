---
--- Linux Process capabilities utility
--- Copyright (c) Appla <bhg@live.it>
---

do
    local jit = jit
    assert(jit and jit.os == 'Linux' and (jit.arch == 'x64' or jit.arch == 'arm64'), "only support Linux x64/arm64 with LuaJIT")
end

local print = print
local tonumber = tonumber
local sprintf = string.format

local bit = require "bit"
local band, bor, lshift = bit.band, bit.bor, bit.lshift

local ffi = require "ffi"
local ffi_string = ffi.string
local ffi_errno = ffi.errno

ffi.cdef [[
    int prctl(int option, ...);
    int getpid();
    uint32_t getuid();
    char *strerror(int errnum);
    long syscall(long number, ...);
]]

do
    if not pcall(ffi.typeof, "td_cap_header_t") then
        ffi.cdef [[
            typedef struct {
                uint32_t version;
                int      pid;
            } td_cap_header_t;

            typedef struct {
                uint32_t effective;
                uint32_t permitted;
                uint32_t inheritable;
            } td_cap_data_t;
        ]]
    end
end

local C = ffi.C

--- log functions
local log_err, log_info, log_debug

local DEBUG = false

local _M = {
    _VERSION = "1.0.0.26051401",
}

do
    if ngx then
        local ngx = ngx
        local ngx_log = ngx.log
        local LOG_DEBUG = ngx.DEBUG
        local LOG_ERR = ngx.ERR
        local LOG_NOTICE = ngx.NOTICE

        log_err = function(...)
            return ngx_log(LOG_ERR, ...);
        end
        log_info = function(...)
            return ngx_log(LOG_NOTICE, ...);
        end
        log_debug = function(...)
            return ngx_log(LOG_DEBUG, ...);
        end
    else
        log_err = print
        log_info = print
        log_debug = print
    end
    if not DEBUG then
        log_debug = function(...)
        end
    end
end

local function str_error(errno)
    local s = ffi_string(C.strerror(errno))
    return s
end

local prctl_arg2l
do
    local long_ct = ffi.typeof("long")

    function prctl_arg2l(op, arg1)
        local rc = C.prctl(op, long_ct(arg1))
        if rc ~= 0 then
            local errno = ffi_errno()
            local err_msg = sprintf("prctl failed op=%d, arg1=%d, err: %s (errno=%d)", op, arg1, str_error(errno), errno)
            return nil, err_msg
        end
        return true
    end

    local PR_SET_KEEPCAPS = 8
    local PR_SET_SECUREBITS = 28
    local SECBIT_NO_SETUID_FIXUP = 4            -- 1<<2
    local SECBIT_KEEP_CAPS = 16                 -- 1<<4

    local function set_secure_bits(bits)
        return prctl_arg2l(PR_SET_SECUREBITS, bits)
    end

    local function inherit_all_caps()
        return set_secure_bits(bor(SECBIT_NO_SETUID_FIXUP, SECBIT_KEEP_CAPS))
    end
    _M.inherit_all_caps = inherit_all_caps

    local function inherit_caps()
        return set_secure_bits(SECBIT_KEEP_CAPS)
    end

    _M.inherit_caps = inherit_caps

    local function inherit_permitted_caps()
        return prctl_arg2l(PR_SET_KEEPCAPS, 1)
    end

    _M.inherit_permitted_caps = inherit_permitted_caps
end

do
    local _LINUX_CAPABILITY_VERSION_3 = 0x20080522
    local SYS_capget, SYS_capset = 125, 126
    if jit.arch == "arm64" then
        SYS_capget, SYS_capset = 90, 91
    end
    local CAP_NET_ADMIN = 12
    local CAP_NET_ADMIN_MASK = lshift(1, CAP_NET_ADMIN)

    local cap_hdr_cd = ffi.new("td_cap_header_t")
    --local cap_data_cd  = ffi.new("td_cap_data_t")
    local cap_data_cd_x64 = ffi.new("td_cap_data_t[2]")
    local cap_data_cd_ct_vec2 = ffi.typeof("td_cap_data_t[2]")

    local function capget(pid)
        local hdr = cap_hdr_cd
        hdr.version = _LINUX_CAPABILITY_VERSION_3
        hdr.pid = pid or 0

        local data = cap_data_cd_ct_vec2()
        local ret = C.syscall(SYS_capget, hdr, data)
        if ret ~= 0 then
            local e = ffi_errno()
            return nil, nil, sprintf("capget failed: %s (errno=%d)", str_error(e), e)
        end

        return data[0], data[1]
    end

    local function capset(effective_lo, permitted_lo, inheritable_lo,
                          effective_hi, permitted_hi, inheritable_hi)
        local hdr = cap_hdr_cd
        --local data = cap_data_cd_ct_vec2()
        local data = cap_data_cd_x64

        hdr.version = _LINUX_CAPABILITY_VERSION_3
        hdr.pid = 0

        data[0].effective = effective_lo
        data[0].permitted = permitted_lo
        data[0].inheritable = inheritable_lo

        data[1].effective = effective_hi or 0
        data[1].permitted = permitted_hi or 0
        data[1].inheritable = inheritable_hi or 0

        local ret = C.syscall(SYS_capset, hdr, data)
        if ret ~= 0 then
            local e = ffi_errno()
            return false, sprintf("capset failed: %s (errno=%d)", str_error(e), e)
        end

        return true
    end

    local function dump_caps(pid)
        local lo, hi, err = capget(pid)
        if err then
            return nil, err
        end
        return sprintf(
                "E=0x%08x P=0x%08x I=0x%08x (hi: E=0x%08x P=0x%08x I=0x%08x)",
                lo.effective, lo.permitted, lo.inheritable,
                hi.effective, hi.permitted, hi.inheritable
        )
    end

    local function raise_net_admin()
        local lo, hi, err = capget(0)
        if err then
            return false, err
        end

        log_info("caps before raise: ", sprintf(
                "E=0x%x P=0x%x I=0x%x",
                lo.effective, lo.permitted, lo.inheritable
        ))

        if band(lo.permitted, CAP_NET_ADMIN_MASK) == 0 then
            return false, "CAP_NET_ADMIN not in Permitted set - check setcap"
        end

        local new_effective = bor(lo.effective, CAP_NET_ADMIN_MASK)

        local ok, cerr = capset(
                new_effective, lo.permitted, lo.inheritable, -- low
                hi.effective, hi.permitted, hi.inheritable   -- high (unchanged)
        )
        if not ok then
            return false, cerr
        end

        log_info("caps after raise:  ", sprintf(
                "E=0x%x P=0x%x I=0x%x",
                new_effective, lo.permitted, lo.inheritable
        ))

        return true
    end

    _M.capget = capget
    _M.capset = capset
    _M.dump_caps = dump_caps
    _M.raise_net_admin = raise_net_admin
end

local function get_pid()
    local pid = C.getpid()
    return tonumber(pid)
end

_M.getpid = get_pid

local function get_uid()
    local uid = C.getuid()
    return tonumber(uid)
end

_M.getuid = get_uid

return _M
