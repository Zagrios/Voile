/* Decodes an H.264 byte stream (Annex B) through Media Foundation's H.264
 * decoder transform, as engines that read the movie file themselves do. It
 * prints the output formats the decoder offers and how many frames came out,
 * and exits 0 once frames decoded and the first one's centre has the expected
 * luma, if one is given.
 *
 * x86_64-w64-mingw32-clang -O2 -o mf-h264-decoder.exe mf-h264-decoder.c \
 *     -lmfplat -lmfuuid -lole32
 * ffmpeg -i movie.mp4 -an -c:v copy -bsf:v h264_mp4toannexb -f h264 movie.h264
 * mf-h264-decoder.exe movie.h264 100
 */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mftransform.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

static const GUID decoder_clsid =
    { 0x62ce7e72, 0x4c71, 0x4d20, { 0xb1, 0x5d, 0x45, 0x28, 0x31, 0xa8, 0x7d, 0x9d } };

static unsigned frames;
static int first_luma = -1;
static UINT32 width, height;

/* Picks NV12 when the decoder offers it, else the first format, and prints
 * every one it offers. */
static HRESULT choose_output(IMFTransform *decoder)
{
    IMFMediaType *type, *chosen = NULL;
    GUID subtype;
    UINT64 size;
    DWORD i;
    HRESULT hr;

    printf("output formats:");
    for (i = 0; SUCCEEDED(IMFTransform_GetOutputAvailableType(decoder, 0, i, &type)); i++) {
        IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
        printf(" %.4s", (const char *)&subtype.Data1);
        if (!chosen || IsEqualGUID(&subtype, &MFVideoFormat_NV12)) {
            if (chosen)
                IMFMediaType_Release(chosen);
            chosen = type;
        } else {
            IMFMediaType_Release(type);
        }
    }
    printf("\n");
    if (!chosen)
        return E_FAIL;
    IMFMediaType_GetGUID(chosen, &MF_MT_SUBTYPE, &subtype);
    if (SUCCEEDED(IMFMediaType_GetUINT64(chosen, &MF_MT_FRAME_SIZE, &size))) {
        width = size >> 32;
        height = (UINT32)size;
    }
    printf("decoding to %.4s, %ux%u\n", (const char *)&subtype.Data1, width, height);
    hr = IMFTransform_SetOutputType(decoder, 0, chosen, 0);
    IMFMediaType_Release(chosen);
    return hr;
}

/* Takes every frame the decoder has ready. Every format it offers starts with
 * a full-size luma plane, whose centre the first frame records. */
static HRESULT drain_output(IMFTransform *decoder)
{
    for (;;) {
        MFT_OUTPUT_STREAM_INFO info;
        MFT_OUTPUT_DATA_BUFFER output = { 0 };
        IMFMediaBuffer *buffer = NULL;
        DWORD status = 0;
        HRESULT hr;

        IMFTransform_GetOutputStreamInfo(decoder, 0, &info);
        if (!(info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES))) {
            MFCreateSample(&output.pSample);
            MFCreateMemoryBuffer(info.cbSize, &buffer);
            IMFSample_AddBuffer(output.pSample, buffer);
        }
        hr = IMFTransform_ProcessOutput(decoder, 0, 1, &output, &status);
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (output.pSample)
                IMFSample_Release(output.pSample);
            if (buffer)
                IMFMediaBuffer_Release(buffer);
            if (FAILED(hr = choose_output(decoder)))
                return hr;
            continue;
        }
        if (SUCCEEDED(hr)) {
            if (!frames++ && width && height) {
                IMFMediaBuffer *contiguous;
                BYTE *data;
                DWORD length;
                if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(output.pSample, &contiguous))) {
                    if (SUCCEEDED(IMFMediaBuffer_Lock(contiguous, &data, NULL, &length))) {
                        DWORD offset = (height / 2) * width + width / 2;
                        if (offset < length)
                            first_luma = data[offset];
                        IMFMediaBuffer_Unlock(contiguous);
                    }
                    IMFMediaBuffer_Release(contiguous);
                }
            }
        }
        if (output.pSample)
            IMFSample_Release(output.pSample);
        if (buffer)
            IMFMediaBuffer_Release(buffer);
        if (output.pEvents)
            IMFCollection_Release(output.pEvents);
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
            return S_OK;
        if (FAILED(hr)) {
            printf("output failed, %#lx\n", hr);
            return hr;
        }
    }
}

int main(int argc, char **argv)
{
    IMFTransform *decoder;
    IMFMediaType *input;
    BYTE *stream;
    long size, offset;
    FILE *file;
    HRESULT hr;
    int expected = -1;

    if (argc < 2) {
        fprintf(stderr, "usage: mf-h264-decoder.exe <stream.h264> [luma]\n");
        return 2;
    }
    if (!(file = fopen(argv[1], "rb"))) {
        printf("cannot open %s\n", argv[1]);
        return 1;
    }
    fseek(file, 0, SEEK_END);
    size = ftell(file);
    fseek(file, 0, SEEK_SET);
    stream = malloc(size);
    fread(stream, 1, size, file);
    fclose(file);

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);
    hr = CoCreateInstance(&decoder_clsid, NULL, CLSCTX_INPROC_SERVER, &IID_IMFTransform, (void **)&decoder);
    if (FAILED(hr)) {
        printf("no H.264 decoder, %#lx\n", hr);
        return 1;
    }
    MFCreateMediaType(&input);
    IMFMediaType_SetGUID(input, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(input, &MF_MT_SUBTYPE, &MFVideoFormat_H264);
    if (FAILED(hr = IMFTransform_SetInputType(decoder, 0, input, 0))) {
        printf("input type refused, %#lx\n", hr);
        return 1;
    }
    if (FAILED(hr = choose_output(decoder))) {
        printf("output type refused, %#lx\n", hr);
        return 1;
    }
    IMFTransform_ProcessMessage(decoder, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    IMFTransform_ProcessMessage(decoder, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    for (offset = 0; offset < size;) {
        long chunk = size - offset < 4096 ? size - offset : 4096;
        IMFMediaBuffer *buffer;
        IMFSample *sample;
        BYTE *data;
        MFCreateMemoryBuffer(chunk, &buffer);
        IMFMediaBuffer_Lock(buffer, &data, NULL, NULL);
        memcpy(data, stream + offset, chunk);
        IMFMediaBuffer_Unlock(buffer);
        IMFMediaBuffer_SetCurrentLength(buffer, chunk);
        MFCreateSample(&sample);
        IMFSample_AddBuffer(sample, buffer);
        hr = IMFTransform_ProcessInput(decoder, 0, sample, 0);
        IMFSample_Release(sample);
        IMFMediaBuffer_Release(buffer);
        if (hr == MF_E_NOTACCEPTING) {
            if (FAILED(drain_output(decoder)))
                return 1;
            continue;
        }
        if (FAILED(hr)) {
            printf("input failed, %#lx\n", hr);
            return 1;
        }
        offset += chunk;
        if (FAILED(drain_output(decoder)))
            return 1;
    }
    IMFTransform_ProcessMessage(decoder, MFT_MESSAGE_COMMAND_DRAIN, 0);
    drain_output(decoder);

    printf("frames: %u, first centre luma %d\n", frames, first_luma);
    if (argc > 2) {
        expected = atoi(argv[2]);
        printf("luma: %s\n", abs(first_luma - expected) <= 10 ? "as expected" : "wrong");
    }
    IMFTransform_Release(decoder);
    MFShutdown();
    return frames && (expected < 0 || abs(first_luma - expected) <= 10) ? 0 : 1;
}
