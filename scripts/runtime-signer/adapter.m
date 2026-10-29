#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <copyfile.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "codesign.h"
#include "coretrust_bug.h"
#include "FAT.h"
#include "MachO.h"
#include "FileStream.h"
#include "Host.h"

#define CPU_SUBTYPE_ARM64E_ABI_V2 0x80000000

static void usage(void) {
    fprintf(stderr, "usage: codex-sign [--adhoc-only] [--entitlements plist] file [file ...]\n");
}

static int copy_slice(const char *input, const char *output) {
    FAT *fat = fat_init_from_path(input);
    if (!fat) {
        fprintf(stderr, "codex-sign: %s is not a readable Mach-O\n", input);
        return -1;
    }
    MachO *macho = fat_find_preferred_slice(fat);
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
    if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_V8);
    if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
    if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_ARM64E_ABI_V2);
    if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E);
#endif
    if (!macho) {
        fprintf(stderr, "codex-sign: no preferred arm64 slice in %s\n", input);
        fat_free(fat);
        return -1;
    }
    MemoryStream *source = macho_get_stream(macho);
    MemoryStream *dest = file_stream_init_from_path(output, 0, 0,
        FILE_STREAM_FLAG_WRITABLE | FILE_STREAM_FLAG_AUTO_EXPAND);
    if (!source || !dest || memory_stream_copy_data(source, 0, dest, 0,
        memory_stream_get_size(source)) != 0) {
        fprintf(stderr, "codex-sign: failed extracting preferred slice from %s\n", input);
        if (dest) memory_stream_free(dest);
        fat_free(fat);
        return -1;
    }
    memory_stream_free(dest);
    fat_free(fat);
    return 0;
}

static int make_temp_for(const char *path, char **result) {
    size_t n = strlen(path) + 32;
    char *template = calloc(1, n);
    if (!template) return -1;
    snprintf(template, n, "%s.codex-sign.XXXXXX", path);
    int fd = mkstemp(template);
    if (fd < 0) {
        free(template);
        return -1;
    }
    close(fd);
    *result = template;
    return 0;
}

static int preserve_attributes(const char *path, const struct stat *st) {
    if (chmod(path, st->st_mode & ALLPERMS) != 0) return -1;
    if (chown(path, st->st_uid, st->st_gid) != 0 && errno != EPERM) return -1;
    return 0;
}

static NSDictionary *read_entitlements(const char *path) {
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) return nil;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    NSError *error = nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&error];
    if (error || ![value isKindOfClass:[NSDictionary class]]) return nil;
    return (NSDictionary *)value;
}

typedef struct {
    const char *input;
    char *work;
    char *slice;
    char *backup;
    struct stat original;
    bool committed;
    bool backupMoved;
} SignJob;

static void discard_job(SignJob *job) {
    if (!job) return;
    if (job->slice) unlink(job->slice);
    if (job->work) unlink(job->work);
    if (job->backup) unlink(job->backup);
    free(job->slice);
    free(job->work);
    free(job->backup);
    job->slice = NULL;
    job->work = NULL;
    job->backup = NULL;
}

static int stage_job(SignJob *job, bool adhocOnly, NSDictionary *entitlements) {
    if (lstat(job->input, &job->original) != 0) {
        fprintf(stderr, "codex-sign: stat %s: %s\n", job->input, strerror(errno));
        return -1;
    }
    if (!S_ISREG(job->original.st_mode)) {
        fprintf(stderr, "codex-sign: refusing non-regular file %s\n", job->input);
        return -1;
    }
    if (make_temp_for(job->input, &job->work) != 0 ||
        copyfile(job->input, job->work, NULL, COPYFILE_ALL) != 0 ||
        chmod(job->work, job->original.st_mode & ALLPERMS) != 0) {
        fprintf(stderr, "codex-sign: failed staging %s: %s\n", job->input, strerror(errno));
        return -1;
    }
    if (make_temp_for(job->input, &job->slice) != 0 || copy_slice(job->work, job->slice) != 0) return -1;
    int signResult = codesign_sign_adhoc(job->slice, true, entitlements);
    if (signResult != 0) {
        fprintf(stderr, "codex-sign: ad-hoc signing failed for %s (%d)\n", job->input, signResult);
        return -1;
    }
    if (!adhocOnly) {
        signResult = apply_coretrust_bypass(job->slice);
        if (signResult != 0) {
            fprintf(stderr, "codex-sign: CoreTrust signing failed for %s (%d)\n", job->input, signResult);
            return -1;
        }
    }
    unlink(job->work);
    if (copyfile(job->slice, job->work, NULL, COPYFILE_ALL) != 0 ||
        preserve_attributes(job->work, &job->original) != 0) {
        fprintf(stderr, "codex-sign: failed finalizing staged %s: %s\n", job->input, strerror(errno));
        return -1;
    }
    return 0;
}

static int commit_jobs(SignJob *jobs, int count) {
    int committed = 0;
    for (int i = 0; i < count; i++) {
        if (make_temp_for(jobs[i].input, &jobs[i].backup) != 0 ||
            rename(jobs[i].input, jobs[i].backup) != 0) {
            fprintf(stderr, "codex-sign: backup replacement failed for %s: %s\n", jobs[i].input, strerror(errno));
            if (jobs[i].backupMoved) {
                unlink(jobs[i].input);
                rename(jobs[i].backup, jobs[i].input);
                jobs[i].backupMoved = false;
            }
            return -1;
        }
        jobs[i].backupMoved = true;
        if (rename(jobs[i].work, jobs[i].input) != 0) {
            fprintf(stderr, "codex-sign: commit replacement failed for %s: %s\n", jobs[i].input, strerror(errno));
            rename(jobs[i].backup, jobs[i].input);
            jobs[i].backupMoved = false;
            for (int j = committed - 1; j >= 0; j--) {
                unlink(jobs[j].input);
                rename(jobs[j].backup, jobs[j].input);
                jobs[j].committed = false;
                jobs[j].backupMoved = false;
            }
            return -1;
        }
        jobs[i].committed = true;
        free(jobs[i].work);
        jobs[i].work = NULL;
        committed++;
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 64; }
        bool adhocOnly = false;
        const char *entitlementsPath = NULL;
        int firstFile = 1;
        while (firstFile < argc) {
            if (!strcmp(argv[firstFile], "--adhoc-only")) {
                if (adhocOnly) { usage(); return 64; }
                adhocOnly = true;
                firstFile++;
            } else if (!strcmp(argv[firstFile], "--entitlements")) {
                if (entitlementsPath || firstFile + 1 >= argc) { usage(); return 64; }
                entitlementsPath = argv[firstFile + 1];
                firstFile += 2;
            } else if (argv[firstFile][0] == '-') {
                usage(); return 64;
            } else {
                break;
            }
        }
        if (firstFile >= argc) { usage(); return 64; }
        NSDictionary *entitlements = nil;
        if (entitlementsPath) {
            entitlements = read_entitlements(entitlementsPath);
            if (!entitlements) {
                fprintf(stderr, "codex-sign: entitlements must be a readable plist dictionary: %s\n", entitlementsPath);
                return 65;
            }
        }
        int count = argc - firstFile;
        SignJob *jobs = calloc((size_t)count, sizeof(*jobs));
        if (!jobs) return 70;
        int failed = 0;
        for (int i = 0; i < count; i++) {
            jobs[i].input = argv[firstFile + i];
            if (stage_job(&jobs[i], adhocOnly, entitlements) != 0) failed = 1;
        }
        if (!failed && commit_jobs(jobs, count) != 0) failed = 1;
        for (int i = 0; i < count; i++) discard_job(&jobs[i]);
        free(jobs);
        return failed ? 1 : 0;
    }
}
