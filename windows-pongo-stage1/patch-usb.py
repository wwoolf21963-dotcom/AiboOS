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

# The pinned upstream asynchronous transfer implementation may free a submitted
# transfer after an event-loop error, before its completion callback. libusb
# requires the callback to finish before the transfer or its buffer is freed.
# Keep the upstream abort schedule and request bytes unchanged. Fail closed on
# transport errors instead of processing stale results or retrying exploits.
start = src.index("bool send_usb_control_request_async(")
end = src.index("void init_usb_handle(", start)
old = src[start:end]
if not all(x in old for x in ("libusb_submit_transfer(transfer)", "libusb_cancel_transfer(transfer)", "libusb_free_transfer(transfer)", "while(completed == 0")):
    raise SystemExit("Upstream async transfer changed; refusing to patch")
replacement = r'''bool send_usb_control_request_async(const usb_handle_t *handle,
                                    uint8_t bm_request_type,
                                    uint8_t b_request,
                                    uint16_t w_value,
                                    uint16_t w_index,
                                    void *p_data,
                                    size_t w_len,
                                    unsigned usb_abort_timeout,
                                    transfer_ret_t *transfer_ret)
{
    static unsigned diagnostic_count = 0;
    struct libusb_transfer *transfer;
    struct timeval tv;
    int completed = 0;
    int rc;
    uint8_t *buf;

    if(transfer_ret != NULL)
    {
        transfer_ret->ret = USB_TRANSFER_ERROR;
        transfer_ret->sz = 0;
    }
    if(w_len > UINT16_MAX || (w_len != 0 && p_data == NULL))
        return false;
    transfer = libusb_alloc_transfer(0);
    if(transfer == NULL)
        return false;
    buf = malloc(LIBUSB_CONTROL_SETUP_SIZE + w_len);
    if(buf == NULL)
    {
        libusb_free_transfer(transfer);
        return false;
    }
    if(w_len != 0 && (bm_request_type & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_OUT)
        memcpy(buf + LIBUSB_CONTROL_SETUP_SIZE, p_data, w_len);
    libusb_fill_control_setup(buf, bm_request_type, b_request, w_value, w_index, (uint16_t)w_len);
    libusb_fill_control_transfer(transfer, handle->device, buf, usb_async_cb, &completed, usb_timeout);
    rc = libusb_submit_transfer(transfer);
    if(rc != LIBUSB_SUCCESS)
    {
        fprintf(stderr, "[AiboOS USB] Async submission failed: %s. Stopping.\\n", libusb_error_name(rc));
        free(buf);
        libusb_free_transfer(transfer);
        exit(EXIT_FAILURE);
    }

    tv.tv_sec = usb_abort_timeout / 1000;
    tv.tv_usec = (usb_abort_timeout % 1000) * 1000;
    rc = libusb_handle_events_timeout_completed(NULL, &tv, &completed);
    if(!completed)
    {
        int cancel_result = libusb_cancel_transfer(transfer);
        if(cancel_result != LIBUSB_SUCCESS && cancel_result != LIBUSB_ERROR_NOT_FOUND)
        {
            fprintf(stderr, "[AiboOS USB] Async cancellation failed: %s; stopping without freeing an active transfer.\\n",
                    libusb_error_name(cancel_result));
            exit(EXIT_FAILURE);
        }
        // Cancellation is asynchronous. Consume its callback exactly once,
        // even when the initial event wait returned an error.
        for(unsigned drain = 0; !completed && drain < 50; ++drain)
        {
            struct timeval wait = {0, 20000};
            int drain_result = libusb_handle_events_timeout_completed(NULL, &wait, &completed);
            if(drain_result != LIBUSB_SUCCESS && drain_result != LIBUSB_ERROR_INTERRUPTED)
            {
                fprintf(stderr, "[AiboOS USB] Event drain failed: %s; stopping.\\n",
                        libusb_error_name(drain_result));
                exit(EXIT_FAILURE);
            }
        }
        if(!completed)
        {
            fprintf(stderr, "[AiboOS USB] No cancellation callback; stopping without freeing an active transfer.\\n");
            exit(EXIT_FAILURE);
        }
    }
    if(rc != LIBUSB_SUCCESS && rc != LIBUSB_ERROR_INTERRUPTED)
    {
        fprintf(stderr, "[AiboOS USB] Initial event wait failed: %s; stopping.\\n", libusb_error_name(rc));
        free(buf);
        libusb_free_transfer(transfer);
        exit(EXIT_FAILURE);
    }

    ++diagnostic_count;
    if(diagnostic_count <= 6 || diagnostic_count % 200 == 0)
        fprintf(stderr, "[AiboOS USB] Async #%u status=%s bytes=%d/%u abort=%ums\\n",
                diagnostic_count, libusb_error_name(transfer->status),
                transfer->actual_length, (unsigned)w_len, usb_abort_timeout);

    if(transfer->status == LIBUSB_TRANSFER_NO_DEVICE ||
       transfer->status == LIBUSB_TRANSFER_OVERFLOW ||
       transfer->actual_length < 0 || (size_t)transfer->actual_length > w_len)
    {
        fprintf(stderr, "[AiboOS USB] Disconnected device or invalid transfer length; stopping.\\n");
        free(buf);
        libusb_free_transfer(transfer);
        exit(EXIT_FAILURE);
    }
    if((bm_request_type & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN && transfer->actual_length > 0)
        memcpy(p_data, libusb_control_transfer_get_data(transfer), (size_t)transfer->actual_length);
    if(transfer_ret != NULL)
    {
        transfer_ret->sz = (uint32_t)transfer->actual_length;
        switch(transfer->status)
        {
            case LIBUSB_TRANSFER_COMPLETED: transfer_ret->ret = USB_TRANSFER_OK; break;
            case LIBUSB_TRANSFER_STALL: transfer_ret->ret = USB_TRANSFER_STALL; break;
            case LIBUSB_TRANSFER_TIMED_OUT: transfer_ret->ret = USB_TRANSFER_TIMEOUT; break;
            default: transfer_ret->ret = USB_TRANSFER_ERROR; break;
        }
    }
    free(buf);
    libusb_free_transfer(transfer);
    return true;
}

'''
src = src[:start] + replacement + src[end:]
path.write_text(src, encoding="utf-8")
print("Patched async transfer lifetime, cancellation completion and bounded transport diagnostics.")
