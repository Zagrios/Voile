/* Plays a movie through Media Foundation's source reader, as games play their
 * videos: its video as RGB32 frames and its audio as PCM. It prints the formats
 * its media source offers and what came out. It exits 0 when the video and any
 * audio decoded and the first frame's centre has the expected colour, if one is
 * given. Wine's source decodes itself, so it offers NV12 and PCM; Windows's
 * offers what the file holds, such as H264 and AAC.
 *
 * x86_64-w64-mingw32-clang -O2 -o mf-video-smoke.exe mf-video-smoke.c \
 *     -lmfplat -lmfreadwrite -lmfuuid -lole32
 * mf-video-smoke.exe movie.mp4 3366CC
 */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

#define VIDEO MF_SOURCE_READER_FIRST_VIDEO_STREAM
#define AUDIO MF_SOURCE_READER_FIRST_AUDIO_STREAM

/* The format the media source offers for a stream, such as NV12 or 0x1 (PCM). */
static void print_native_type(IMFSourceReader *reader, DWORD stream, const char *name)
{
    IMFMediaType *type;
    GUID subtype;
    if (FAILED(IMFSourceReader_GetNativeMediaType(reader, stream, 0, &type))) {
        printf("%s: none\n", name);
        return;
    }
    IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
    if (subtype.Data1 > 0xffff)
        printf("%s: the source offers %.4s\n", name, (const char *)&subtype.Data1);
    else
        printf("%s: the source offers format %#lx\n", name, subtype.Data1);
    IMFMediaType_Release(type);
}

static HRESULT ask_for(IMFSourceReader *reader, DWORD stream, const GUID *major, const GUID *subtype)
{
    IMFMediaType *type;
    HRESULT hr = MFCreateMediaType(&type);
    if (FAILED(hr))
        return hr;
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, major);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
    hr = IMFSourceReader_SetCurrentMediaType(reader, stream, NULL, type);
    IMFMediaType_Release(type);
    return hr;
}

/* The BGRA pixel at the centre of an RGB32 frame. */
static DWORD centre_pixel(IMFSourceReader *reader, IMFSample *sample)
{
    IMFMediaType *type;
    IMFMediaBuffer *buffer;
    UINT64 size = 0;
    UINT32 width, height, stride = 0;
    BYTE *data;
    DWORD pixel = 0, length;

    IMFSourceReader_GetCurrentMediaType(reader, VIDEO, &type);
    IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &size);
    width = size >> 32;
    height = (UINT32)size;
    if (FAILED(IMFMediaType_GetUINT32(type, &MF_MT_DEFAULT_STRIDE, &stride)))
        stride = width * 4;
    IMFMediaType_Release(type);
    printf("video: %ux%u\n", width, height);
    if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buffer))) {
        if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length))) {
            DWORD offset = (height / 2) * abs((INT32)stride) + (width / 2) * 4;
            if (offset + 4 <= length)
                memcpy(&pixel, data + offset, 4);
            IMFMediaBuffer_Unlock(buffer);
        }
        IMFMediaBuffer_Release(buffer);
    }
    return pixel;
}

/* The loudest 16-bit sample of a PCM buffer. */
static int peak(IMFSample *sample)
{
    IMFMediaBuffer *buffer;
    BYTE *data;
    DWORD length, i;
    int loudest = 0;
    if (FAILED(IMFSample_ConvertToContiguousBuffer(sample, &buffer)))
        return 0;
    if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length))) {
        for (i = 0; i + 1 < length; i += 2) {
            int value = abs(*(INT16 *)(data + i));
            if (value > loudest)
                loudest = value;
        }
        IMFMediaBuffer_Unlock(buffer);
    }
    IMFMediaBuffer_Release(buffer);
    return loudest;
}

static int close_to(int a, int b)
{
    return abs(a - b) <= 12;
}

int main(int argc, char **argv)
{
    WCHAR path[MAX_PATH];
    IMFAttributes *attributes;
    IMFSourceReader *reader;
    unsigned frames = 0, buffers = 0, loudest = 0;
    DWORD pixel = 0, expected = 0;
    BOOL video_done = FALSE, audio_done = FALSE, has_audio = TRUE, checked = TRUE;
    HRESULT hr;

    if (argc < 2) {
        fprintf(stderr, "usage: mf-video-smoke.exe <movie> [RRGGBB]\n");
        return 2;
    }
    MultiByteToWideChar(CP_ACP, 0, argv[1], -1, path, MAX_PATH);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);

    MFCreateAttributes(&attributes, 1);
    IMFAttributes_SetUINT32(attributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    hr = MFCreateSourceReaderFromURL(path, attributes, &reader);
    if (FAILED(hr)) {
        printf("open: %#lx\n", hr);
        return 1;
    }
    print_native_type(reader, VIDEO, "video");
    print_native_type(reader, AUDIO, "audio");
    if (FAILED(hr = ask_for(reader, VIDEO, &MFMediaType_Video, &MFVideoFormat_RGB32))) {
        printf("video: no RGB32 output, %#lx\n", hr);
        video_done = TRUE;
    }
    if (FAILED(hr = ask_for(reader, AUDIO, &MFMediaType_Audio, &MFAudioFormat_PCM))) {
        printf("audio: no PCM output, %#lx\n", hr);
        audio_done = TRUE;
        has_audio = FALSE;
    }

    while (!video_done) {
        IMFSample *sample = NULL;
        DWORD flags = 0;
        LONGLONG time;
        hr = IMFSourceReader_ReadSample(reader, VIDEO, 0, NULL, &flags, &time, &sample);
        if (FAILED(hr)) {
            printf("video: read failed, %#lx\n", hr);
            break;
        }
        if (sample) {
            if (!frames++)
                pixel = centre_pixel(reader, sample);
            IMFSample_Release(sample);
        }
        video_done = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
    }
    while (!audio_done) {
        IMFSample *sample = NULL;
        DWORD flags = 0;
        LONGLONG time;
        hr = IMFSourceReader_ReadSample(reader, AUDIO, 0, NULL, &flags, &time, &sample);
        if (FAILED(hr)) {
            printf("audio: read failed, %#lx\n", hr);
            break;
        }
        if (sample) {
            int value = peak(sample);
            if (value > (int)loudest)
                loudest = value;
            buffers++;
            IMFSample_Release(sample);
        }
        audio_done = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
    }

    printf("video: %u frames, centre #%02lX%02lX%02lX\n", frames, (pixel >> 16) & 0xff,
        (pixel >> 8) & 0xff, pixel & 0xff);
    printf("audio: %u buffers, peak %u\n", buffers, loudest);
    if (argc > 2) {
        expected = strtoul(argv[2], NULL, 16);
        checked = close_to((pixel >> 16) & 0xff, (expected >> 16) & 0xff)
            && close_to((pixel >> 8) & 0xff, (expected >> 8) & 0xff)
            && close_to(pixel & 0xff, expected & 0xff);
        printf("colour: %s\n", checked ? "as expected" : "wrong");
    }
    IMFSourceReader_Release(reader);
    MFShutdown();
    return frames && (!has_audio || (buffers && loudest)) && checked ? 0 : 1;
}
