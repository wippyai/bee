/* SPDX-License-Identifier: MIT */
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        puts("2.1.265");
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--help") == 0) {
        puts("--permission-mode --model --effort --append-system-prompt-file");
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "auth") == 0) {
        puts("{\"loggedIn\":true,\"authMethod\":\"fixture\"}");
        return 0;
    }
    puts("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"owner-journey-fixture\"}");
    fflush(stdout);
    for (int index = 1; index < argc; index++) {
        const char *gate = strstr(argv[index], "JOURNEY_GATE=");
        if (gate) {
            gate += strlen("JOURNEY_GATE=");
            if (!strstr(gate, "/.wippy/")) return 2;
            FILE *release = fopen(gate, "r");
            if (!release) { perror("fixture release FIFO"); return 3; }
            if (fgetc(release) == EOF) { fclose(release); return 4; }
            fclose(release);
        }
    }
    puts("{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"OWNER JOURNEY STUB OUTPUT\"}]}}");
    puts("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OWNER JOURNEY STUB OUTPUT\",\"session_id\":\"owner-journey-fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}");
    return 0;
}
