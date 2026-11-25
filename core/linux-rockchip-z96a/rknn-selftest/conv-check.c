#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "rknn_api.h"

enum { INPUT_CHANNELS = 8, INPUT_SIDE = 32, OUTPUT_CHANNELS = 16, OUTPUT_SIDE = 30 };

static double now(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void check(int code, const char *name)
{
    if (code != RKNN_SUCC) {
        fprintf(stderr, "%s returned %d\n", name, code);
        exit(EXIT_FAILURE);
    }
}

static void generate(float *input, float *expected, int frame)
{
    for (int i = 0; i < INPUT_CHANNELS * INPUT_SIDE * INPUT_SIDE; ++i)
        input[i] = ((i * 3 + frame * 5) % 23 - 11) / 16.0f;
    for (int oc = 0; oc < OUTPUT_CHANNELS; ++oc) {
        for (int y = 0; y < OUTPUT_SIDE; ++y) {
            for (int x = 0; x < OUTPUT_SIDE; ++x) {
                float value = (oc - 8) / 4.0f;
                for (int ic = 0; ic < INPUT_CHANNELS; ++ic) {
                    for (int dy = 0; dy < 3; ++dy) {
                        for (int dx = 0; dx < 3; ++dx) {
                            int weight_index = ((oc * INPUT_CHANNELS + ic) * 3 + dy) * 3 + dx;
                            int input_index = ((y + dy) * INPUT_SIDE + x + dx) * INPUT_CHANNELS + ic;
                            value += input[input_index] * ((weight_index % 7 - 3) / 8.0f);
                        }
                    }
                }
                expected[(oc * OUTPUT_SIDE + y) * OUTPUT_SIDE + x] = value;
            }
        }
    }
}

int main(int argc, char **argv)
{
    char *end = NULL;
    long seconds = argc == 3 ? strtol(argv[2], &end, 10) : -1;
    if (argc != 3 || end == argv[2] || *end || seconds < 0 || seconds > 300) {
        fprintf(stderr, "Usage: %s model.rknn duration_seconds\n", argv[0]);
        return EXIT_FAILURE;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    static float inputs[2][INPUT_CHANNELS * INPUT_SIDE * INPUT_SIDE];
    static float expected[2][OUTPUT_CHANNELS * OUTPUT_SIDE * OUTPUT_SIDE];
    for (int frame = 0; frame < 2; ++frame)
        generate(inputs[frame], expected[frame], frame);
    rknn_context ctx = 0;
    check(rknn_init(&ctx, argv[1], 0, 0, NULL), "rknn_init");
    rknn_sdk_version sdk = {0};
    check(rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &sdk, sizeof(sdk)), "query SDK");
    printf("runtime=%s driver=%s\n", sdk.api_version, sdk.drv_version);
    rknn_tensor_attr out = {0};
    check(rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &out, sizeof(out)), "query output");
    printf("output=%s %s [%u,%u,%u,%u], %u values\n", get_type_string(out.type),
           get_format_string(out.fmt), out.dims[0], out.dims[1], out.dims[2], out.dims[3], out.n_elems);
    const int count = OUTPUT_CHANNELS * OUTPUT_SIDE * OUTPUT_SIDE;
    if (out.n_elems != (unsigned)count || out.fmt != RKNN_TENSOR_NCHW)
        return EXIT_FAILURE;
    unsigned runs = 0;
    float max_error = 0.0f;
    const double start = now();
    do {
        const int frame = runs % 2;
        rknn_input input = {.buf = inputs[frame], .size = sizeof(inputs[frame]),
                            .type = RKNN_TENSOR_FLOAT32, .fmt = RKNN_TENSOR_NHWC};
        rknn_output output = {.want_float = 1};
        check(rknn_inputs_set(ctx, 1, &input), "set input");
        check(rknn_run(ctx, NULL), "run");
        check(rknn_outputs_get(ctx, 1, &output, NULL), "get output");
        if (!output.buf || output.size != count * sizeof(float)) {
            fprintf(stderr, "Unexpected output size %u\n", output.size);
            return EXIT_FAILURE;
        }
        const float *values = output.buf;
        if (runs < 2)
            printf("frame=%d expected=[%.6f,%.6f,%.6f] observed=[%.6f,%.6f,%.6f]\n", frame,
                   expected[frame][0], expected[frame][1], expected[frame][2], values[0], values[1], values[2]);
        for (int i = 0; i < count; ++i) {
            const float error = fabsf(values[i] - expected[frame][i]);
            if (!isfinite(error) || error > 1e-3f) {
                fprintf(stderr, "Mismatch run=%u value=%d expected=%.6f observed=%.6f\n",
                        runs, i, expected[frame][i], values[i]);
                return EXIT_FAILURE;
            }
            if (error > max_error)
                max_error = error;
        }
        check(rknn_outputs_release(ctx, 1, &output), "release output");
        ++runs;
    } while (runs < 2 || now() - start < seconds);
    const double elapsed = now() - start;
    rknn_perf_run perf = {0};
    check(rknn_query(ctx, RKNN_QUERY_PERF_RUN, &perf, sizeof(perf)), "query run time");
    printf("PASS runs=%u values_per_run=%d max_abs_error=%.6f duration=%.3fs last_run=%lldus\n",
           runs, count, max_error, elapsed, (long long)perf.run_duration);
    check(rknn_destroy(ctx), "destroy");
    return EXIT_SUCCESS;
}
