#!/usr/bin/env python3
"""Fail-closed Windows libusb compatibility diagnostics for pinned openra1n."""
from pathlib import Path

path = Path("usb_libusb.c")
src = path.read_text(encoding="utf-8")
start = src.index("bool wait_usb_handle(")
end = src.index("static void usb_async_cb(", start)
original = src[start:end]
if "libusb_set_configuration(handle->device, 1)" not in original or "for(;;)" not in original:
    raise SystemExit("Upstream USB wait implementation changed; refusing to patch")
replacement = r'''bool wait_usb_handle(usb_handle_t *handle,
                     usb_check_cb_t usb_check_cb,
                     void *arg)
{
    int rc = libusb_init(NULL);
    if(rc != LIBUSB_SUCCESS)
    {
        fprintf(stderr, "[AiboOS USB] libusb_init failed: %s\n", libusb_error_name(rc));
        return false;
    }
    int last_error = LIBUSB_ERROR_NOT_FOUND;
    for(unsigned attempt = 0; attempt < 120; ++attempt)
    {
        handle->device = libusb_open_device_with_vid_pid(NULL, handle->vid, handle->pid);
        if(handle->device != NULL)
        {
            int active = -1;
            int result = libusb_get_configuration(handle->device, &active);
            bool ready = false;
            if(result == LIBUSB_SUCCESS && active == 1)
            {
                if(attempt == 0)
                    fprintf(stderr, "[AiboOS USB] Configuration 1 already active; skipping set_configuration.\n");
                ready = true;
            }
            else
            {
                int set_result = libusb_set_configuration(handle->device, 1);
                if(set_result == LIBUSB_SUCCESS)
                {
                    ready = true;
                    fprintf(stderr, "[AiboOS USB] Configuration 1 selected successfully.\n");
                }
                else
                {
                    last_error = set_result;
                    if(attempt == 0 || attempt == 119)
                        fprintf(stderr, "[AiboOS USB] USB configuration failed: %s (read=%s, active=%d).\n",
                                libusb_error_name(set_result), libusb_error_name(result), active);
                }
            }
            if(ready)
            {
                if(usb_check_cb == NULL || usb_check_cb(handle, arg))
                    return true;
                if(attempt == 0)
                    fprintf(stderr, "[AiboOS USB] Opened DFU, but identity/serial check failed.\n");
            }
            libusb_close(handle->device);
            handle->device = NULL;
        }
        else if(attempt == 0)
        {
            fprintf(stderr, "[AiboOS USB] Device %04x:%04x not accessible yet.\n",
                    handle->vid, handle->pid);
        }
        if(attempt > 0 && attempt % 30 == 0)
            fprintf(stderr, "[AiboOS USB] Retrying USB access (%u of 120) - no exploit progress yet.\n", attempt);
        sleep_ms(100);
    }
    fprintf(stderr, "[AiboOS USB] STOP: could not open/configure expected device after 120 checks; last error: %s.\n",
            libusb_error_name(last_error));
    libusb_exit(NULL);
    return false;
}

'''
if "#include <stdio.h>" not in src:
    src = src.replace("#include <common.h>", "#include <common.h>\n#include <stdio.h>", 1)
    # insertion occurs before function and is accounted for by recalculating indexes
    start = src.index("bool wait_usb_handle(")
    end = src.index("static void usb_async_cb(", start)
src = src[:start] + replacement + src[end:]
path.write_text(src, encoding="utf-8")
print("Patched bounded Windows USB wait, active config check and failure messages.")
