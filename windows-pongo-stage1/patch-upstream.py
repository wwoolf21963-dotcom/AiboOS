#!/usr/bin/env python3
"""
Bound repeated checkm8 setup/spray attempts in a pinned openra1n checkout.
Fail-closed: do not silently loop forever or automatically restart an exploit.
This deliberately does not alter USB exploit primitives or payload bytes.
"""
from pathlib import Path

source = Path("checkm8.c")
text = source.read_text(encoding="utf-8")

def replace_once(old, new, description):
    global text
    found = text.count(old)
    if found != 1:
        raise SystemExit(f"Refusing to patch {description}: expected one match, found {found}")
    text = text.replace(old, new, 1)

# Identify the exact first-stage DFU reset operation that fails, without
# changing the number or types of USB requests or auto-retrying an exploit.
reset_start = text.index("static bool checkm8_stage_reset(")
reset_end = text.index("static bool checkm8_stage_setup(", reset_start)
reset_old = text[reset_start:reset_end]
reset_new = r'''static bool checkm8_stage_reset(const usb_handle_t *handle)
{
    transfer_ret_t transfer_ret = {0};

    // Same upstream DFU sequence, with distinct fail-closed diagnostics.
    if(!send_usb_control_request_no_data(handle, 0x21, DFU_DNLOAD, 0, 0,
                                          DFU_FILE_SUFFIX_LEN, &transfer_ret))
    {
        LOG_ERROR("A9 DFU reset: initial 16-byte DNLOAD could not be sent.");
        goto fail;
    }
    if(transfer_ret.ret != USB_TRANSFER_OK || transfer_ret.sz != DFU_FILE_SUFFIX_LEN)
    {
        LOG_ERROR("A9 DFU reset: initial DNLOAD status=%u bytes=%u; expected 16 bytes and USB_TRANSFER_OK.",
                  (unsigned)transfer_ret.ret, (unsigned)transfer_ret.sz);
        goto fail;
    }
    if(!dfu_set_state_wait_reset(handle))
    {
        LOG_ERROR("A9 DFU reset: failed DFU manifest state transition.");
        goto fail;
    }
    transfer_ret.ret = USB_TRANSFER_ERROR;
    transfer_ret.sz = 0;
    if(!send_usb_control_request_no_data(handle, 0x21, DFU_DNLOAD, 0, 0,
                                          EP0_MAX_PACKET_SZ, &transfer_ret))
    {
        LOG_ERROR("A9 DFU reset: final 64-byte DNLOAD could not be sent.");
        goto fail;
    }
    if(transfer_ret.ret != USB_TRANSFER_OK || transfer_ret.sz != EP0_MAX_PACKET_SZ)
    {
        LOG_ERROR("A9 DFU reset: final DNLOAD status=%u bytes=%u; expected 64 bytes and USB_TRANSFER_OK.",
                  (unsigned)transfer_ret.ret, (unsigned)transfer_ret.sz);
        goto fail;
    }
    return true;

fail:
    send_usb_control_request_no_data(handle, 0x21, DFU_CLR_STATUS, 0, 0, 0, NULL);
    return false;
}

'''
if not all(marker in reset_old for marker in ("dfu_set_state_wait_reset(handle)", "DFU_FILE_SUFFIX_LEN", "EP0_MAX_PACKET_SZ")):
    raise SystemExit("Upstream DFU reset function changed; refusing to patch")
text = text[:reset_start] + reset_new + text[reset_end:]

start = text.index("static bool checkm8_stage_setup(")
end = text.index("static bool checkm8_usb_request_leak(", start)
setup = text[start:end]
needle = "    for(;;)\n    {\n"
if setup.count(needle) != 1:
    raise SystemExit("Upstream checkm8 heap-spray setup loop changed")
setup = setup.replace(
    needle,
    "    for(unsigned attempt = 0; attempt < 1200; ++attempt)\n"
    "    {\n"
    "        if(attempt && attempt % 200 == 0) {\n"
    "            LOG_INFO(\"Heap-spray setup still attempting USB timing (%u/1200)\", attempt);\n"
    "        }\n",
    1,
)
needle2 = "    return false;\n}\n\n"
if setup.count(needle2) != 1:
    raise SystemExit("Upstream setup return pattern changed")
setup = setup.replace(
    needle2,
    '    LOG_ERROR("Heap-spray setup did not succeed within 1200 USB attempts; stopping.");\n'
    "    return false;\n}\n\n",
    1,
)
text = text[:start] + setup + text[end:]

# The original top-level code silently resets the stage and automatically
# continues through an unlimited number of exploit attempts.
needle3 = '''            else
            {
                LOG_ERROR("Stage %d failed", stage);
                stage = STAGE_RESET;
            }
            reset_usb_handle(handle);'''
repl3 = '''            else
            {
                LOG_ERROR("Stage %d failed; aborting without automatic exploit retry.", stage);
                close_usb_handle(handle);
                return false;
            }
            reset_usb_handle(handle);'''
replace_once(needle3, repl3, "top-level retry handling")

# The S8000/S8003 family also has an unbounded loop in the spray stage.
needle4 = '''        while(!checkm8_usb_request_stall(handle) || !checkm8_usb_request_leak(handle) || !checkm8_no_leak(handle)) {}'''
repl4 = '''        bool success = false;
        for(unsigned attempt = 0; attempt < 1200; ++attempt)
        {
            if(checkm8_usb_request_stall(handle)
               && checkm8_usb_request_leak(handle)
               && checkm8_no_leak(handle))
            {
                success = true;
                break;
            }
        }
        if(!success)
        {
            LOG_ERROR("A9 spray stage did not succeed within 1200 attempts; stopping.");
            return false;
        }'''
replace_once(needle4, repl4, "Apple A9 spray retry limit")

source.write_text(text, encoding="utf-8")
print("Patched known infinite A9 setup/spray retry loops, and disabled automatic top-level retry.")
assert "attempt < 1200" in text
assert "aborting without automatic exploit retry." in text
