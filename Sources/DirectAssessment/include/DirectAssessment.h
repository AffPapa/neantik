#ifndef NEANTIK_DIRECT_ASSESSMENT_H
#define NEANTIK_DIRECT_ASSESSMENT_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

enum {
    NEANTIK_ASSESSMENT_OK = 0, NEANTIK_ASSESSMENT_ENVIRONMENT = 1,
    NEANTIK_ASSESSMENT_REQUEST = 2, NEANTIK_ASSESSMENT_UNAVAILABLE = 3,
    NEANTIK_ASSESSMENT_SIGNATURE = 4, NEANTIK_ASSESSMENT_HASH = 5,
    NEANTIK_ASSESSMENT_DENIED = 6, NEANTIK_ASSESSMENT_OFFLINE_TICKET = 7,
    NEANTIK_ASSESSMENT_ONLINE_TICKET = 8, NEANTIK_ASSESSMENT_CHANGED = 9
};
typedef struct {
    int status;
    double offline_date, online_date;
    int gatekeeper_accepted, offline_ticket_accepted;
    int online_lookup_success, online_date_valid;
    int64_t system_error_code;
} NeAntikAssessmentResult;

/* Pure admission predicates. Labels alone never establish notarization. */
int neantik_assessment_result_admitted(CFDictionaryRef result);
int neantik_assessment_ticket_admitted(int success, int error, double date, double now);
uint64_t neantik_assessment_flags(void);
int neantik_assessment_environment_admitted(char *const *environment);

/* Fresh isolated helper only, before any assessment initialization. Parent
 * must separately bind product identity/profile/runtime and stage custody.
 * This observes system policy/tickets; it grants no installation capability. */
NeAntikAssessmentResult neantik_assessment_observe(const char *canonical_path,
    const uint8_t expected_cdhash[20], uint32_t original_digest_algorithm);
#endif
