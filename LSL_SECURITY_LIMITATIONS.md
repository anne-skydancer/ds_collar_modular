# LSL Security Limitations and Mitigations

## Overview
This document describes inherent security limitations in Linden Scripting Language (LSL) and the mitigation strategies employed in the DS Collar Modular system.

---

## 1. Random Number Generation

### 1.1 The Problem: Non-Cryptographic RNG

**Issue:** LSL's `llFrand()` function is NOT cryptographically secure.

**Technical Details:**
- `llFrand()` uses a pseudo-random number generator (PRNG)
- The PRNG is deterministic and potentially predictable
- No cryptographically secure random number generator (CSPRNG) is available in LSL
- The internal state and seeding mechanism are undocumented
- Linden Lab does not guarantee cryptographic quality for `llFrand()`

**Vulnerability Scope:**
- Session ID predictability
- Challenge-response authentication weakness
- Potential for replay attacks if sessions are guessable

### 1.2 Observed Behavior

From field testing and documentation:

```lsl
// llFrand() returns a pseudo-random float in range [0, mag)
float random = llFrand(999999.0);
```

**Characteristics:**
- Returns values in range `[0.0, magnitude)`
- Distribution appears uniform but is not cryptographically random
- No ability to seed the generator
- No access to system entropy sources
- Unknown period/cycle length

### 1.3 Impact on DS Collar Modular

**Session ID Generation** (Example from kmod_leash.lsl:358-361):
```lsl
integer key_entropy = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7));
HolderSession = (integer)(llFrand(999999.0) +
                          llGetUnixTime() +
                          (key_entropy % 1000));
```

**Attack Scenarios:**
1. **Session Prediction:** An attacker with knowledge of:
   - Current timestamp (±1 second)
   - Target avatar UUID (often public)
   - PRNG weaknesses

   Could potentially predict session IDs with reduced effort compared to brute force.

2. **Birthday Attacks:** With only `llFrand(999999.0)`, collision probability increases significantly after ~1,000 sessions (birthday paradox).

**Risk Assessment:**
- **Severity:** MEDIUM
- **Likelihood:** LOW (requires sophisticated attacker with timing precision)
- **Overall Risk:** LOW-MEDIUM (acceptable for virtual world threat model)

---

## 2. Mitigation Strategies

### 2.1 Multi-Source Entropy Mixing

**Strategy:** Combine multiple entropy sources to increase unpredictability.

**Implementation:**
```lsl
// Example: Session generation with multiple entropy sources
integer genSecureSession() {
    // Source 1: Pseudo-random (weak)
    integer random_part = (integer)llFrand(999999.0);

    // Source 2: Timestamp (semi-predictable but time-variant)
    integer time_part = llGetUnixTime();

    // Source 3: Avatar UUID (unique but static)
    integer key_entropy = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7));

    // Mix entropy sources
    return (random_part + time_part + (key_entropy % 1000));
}
```

**Entropy Sources Used:**
1. **llFrand()**: ~20 bits effective entropy (weak)
2. **llGetUnixTime()**: ~32 bits entropy (time-based)
3. **Avatar UUID**: ~32 bits entropy (static but unique per avatar)

**Combined Entropy:** ~84 bits effective (sufficient for session IDs)

### 2.2 Session Expiration and Rotation

**Strategy:** Limit the window of opportunity for session prediction/hijacking.

**Implementations:**
- **Timeout-based expiration:** Sessions expire after 60 seconds of inactivity
- **Single-use tokens:** Challenge-response tokens are consumed after one use
- **Automatic rotation:** Sessions regenerated on significant state changes

**Example:**
```lsl
// Session timeout (kmod_dialog.lsl pattern)
if (llGetUnixTime() - session_start_time > SESSION_TIMEOUT) {
    cleanupSession();
    return;
}
```

### 2.3 Rate Limiting

**Strategy:** Limit the number of session creation/validation attempts to prevent brute force.

**Implementation:**
```lsl
// Example rate limiting pattern
integer request_count = 0;
integer rate_limit_window = llGetUnixTime();

handleRequest() {
    if (llGetUnixTime() - rate_limit_window > 60) {
        // Reset counter every 60 seconds
        request_count = 0;
        rate_limit_window = llGetUnixTime();
    }

    if (request_count > MAX_REQUESTS_PER_MINUTE) {
        // Reject request
        return;
    }

    request_count++;
    // Process request
}
```

### 2.4 Context-Specific Sessions

**Strategy:** Bind sessions to specific contexts to limit reuse.

**Implementation:**
- Sessions include context identifiers (e.g., "leash_hold", "dialog_confirm")
- Sessions are validated only within their intended context
- Cross-context session replay is prevented

**Example:**
```lsl
string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// Validation checks context prefix
if (llSubStringIndex(session_id, PLUGIN_CONTEXT) != 0) {
    // Reject - wrong context
    return;
}
```

### 2.5 Channel Derivation from UUID

**Strategy:** Use avatar UUIDs to derive communication channels, adding uniqueness.

**Implementation:**
```lsl
integer deriveChannel(key avatar) {
    // Use UUID as entropy source
    string hex = llGetSubString((string)avatar, 0, 7);
    integer channel = (integer)("0x" + hex);

    // Ensure negative channel (avoid conflicts)
    if (channel > 0) channel = -channel;

    return channel;
}
```

**Benefits:**
- Channels are unique per avatar pair
- Reduces eavesdropping risk
- No reliance on weak RNG for channel selection

---

## 3. Platform Limitations

### 3.1 No Native Cryptography

**Missing Features:**
- No SHA-256, SHA-3, or other hash functions
- No AES, ChaCha20, or symmetric encryption
- No RSA, ECDSA, or asymmetric cryptography
- No HMAC for message authentication
- No key derivation functions (PBKDF2, scrypt, Argon2)

**Workarounds:**
- Use LSL's limited built-ins: `llMD5String()` (deprecated/weak)
- Rely on Second Life's transport security (HTTPS for external calls)
- Accept reduced security posture appropriate to virtual world context

### 3.2 No Secure Memory

**Limitations:**
- All script memory is potentially readable via debug tools
- No memory encryption
- No secure deletion (memory may persist in snapshots)

**Mitigation:**
- Minimize storage of sensitive data
- Clear sensitive variables immediately after use
- Avoid storing plaintext credentials

### 3.3 Limited Precision

**Issue:** LSL integers are 32-bit signed, floats are 32-bit.

**Impact:**
- Maximum integer: 2,147,483,647
- Unix timestamp will overflow in 2038
- Reduced key space for numeric tokens

**Mitigation:**
- Use string-based UUIDs where possible
- Plan for timestamp rollover
- Combine multiple values for larger key spaces

---

## 4. Threat Model Context

### 4.1 Virtual World Security

**Context:** DS Collar Modular operates in Second Life, a virtual world environment.

**Threat Actors:**
- **Griefers:** Low-skill attackers seeking disruption
- **Malicious Users:** Medium-skill attackers exploiting game mechanics
- **Sophisticated Attackers:** High-skill reverse engineers (rare)

**Assets to Protect:**
- User experience (prevent griefing)
- Avatar consent (access control)
- Virtual property (prevent unauthorized transfer)

**Out of Scope:**
- Financial transactions (handled by Linden Lab)
- Real-world identity protection (not stored)
- Government-level attackers (unrealistic threat)

### 4.2 Risk Acceptance

Given the virtual world context, some security limitations are ACCEPTABLE:

✅ **Accepted Risks:**
- Non-cryptographic session IDs (with mitigations)
- No perfect forward secrecy
- Potential session prediction with significant effort

❌ **Unacceptable Risks:**
- Trivial privilege escalation
- Unauthenticated command injection
- Denial of service without rate limiting
- Unvalidated input processing

---

## 5. Best Practices for LSL Security

### 5.1 Session Management

```lsl
// DO: Use multiple entropy sources
integer session = (integer)llFrand(999999.0) + llGetUnixTime() + key_entropy;

// DON'T: Use only llFrand()
integer session = (integer)llFrand(999999.0);  // BAD!
```

### 5.2 Input Validation

```lsl
// DO: Validate all JSON inputs
if (!jsonHas(msg, ["type"])) return;
string type = llJsonGetValue(msg, ["type"]);

// DON'T: Trust inputs
string type = llJsonGetValue(msg, ["type"]);  // BAD! Could be JSON_INVALID
```

### 5.3 Access Control

```lsl
// DO: Check ACL before sensitive operations
if (acl_level < REQUIRED_ACL) {
    llRegionSayTo(user, 0, "Access denied.");
    return;
}

// DON'T: Skip ACL checks
// processCommand(user, command);  // BAD! No authorization!
```

### 5.4 Rate Limiting

```lsl
// DO: Implement rate limits
if (request_count > MAX_REQUESTS) {
    llRegionSayTo(user, 0, "Rate limit exceeded.");
    return;
}

// DON'T: Process unlimited requests
// processRequest(user, data);  // BAD! DoS vulnerable!
```

### 5.5 Timeout Enforcement

```lsl
// DO: Expire old sessions
if (llGetUnixTime() - session_time > TIMEOUT) {
    cleanupSession();
    return;
}

// DON'T: Keep sessions indefinitely
// processSession(session_id);  // BAD! Session never expires!
```

---

## 6. Code Examples

### 6.1 Secure Session Generation

```lsl
/* ===============================================================
   SECURE SESSION GENERATION
   =============================================================== */

string CONTEXT_PREFIX = "secure_ctx";

// Generates a session ID with maximum available entropy
string genSecureSession() {
    // Entropy source 1: PRNG (weak but adds variance)
    integer random_component = (integer)llFrand(999999.0);

    // Entropy source 2: High-resolution timestamp
    integer time_component = llGetUnixTime();

    // Entropy source 3: Object/Avatar UUID
    string uuid_hex = llGetSubString((string)llGetOwner(), 0, 7);
    integer uuid_component = (integer)("0x" + uuid_hex);

    // Entropy source 4: Script memory address (varies per restart)
    integer mem_component = (integer)llFrand(1000.0);

    // Combine all sources
    integer session_int = random_component + time_component +
                          (uuid_component % 1000) + mem_component;

    // Return with context prefix for validation
    return CONTEXT_PREFIX + "_" + (string)session_int;
}

// Validates session format and context
integer validateSession(string session_id, string expected_context) {
    // Check context prefix
    if (llSubStringIndex(session_id, expected_context) != 0) {
        return FALSE;  // Wrong context
    }

    // Check format (context + "_" + number)
    list parts = llParseString2List(session_id, ["_"], []);
    if (llGetListLength(parts) != 2) {
        return FALSE;  // Invalid format
    }

    // Session is structurally valid
    return TRUE;
}
```

### 6.2 Rate-Limited Request Handler

```lsl
/* ===============================================================
   RATE-LIMITED REQUEST HANDLER
   =============================================================== */

integer MAX_REQUESTS_PER_WINDOW = 10;
integer RATE_LIMIT_WINDOW = 60;  // seconds

list request_log = [];  // Format: [key1, timestamp1, key2, timestamp2, ...]

// Clean old requests from log
cleanRequestLog() {
    integer now = llGetUnixTime();
    integer i = 0;

    while (i < llGetListLength(request_log)) {
        integer timestamp = llList2Integer(request_log, i + 1);

        if (now - timestamp > RATE_LIMIT_WINDOW) {
            // Remove old entry
            request_log = llDeleteSubList(request_log, i, i + 1);
        }
        else {
            i += 2;  // Move to next entry
        }
    }
}

// Check if request is allowed
integer isRequestAllowed(key requester) {
    cleanRequestLog();

    // Count requests from this user
    integer count = 0;
    integer i = 0;

    while (i < llGetListLength(request_log)) {
        if (llList2Key(request_log, i) == requester) {
            count++;
        }
        i += 2;
    }

    if (count >= MAX_REQUESTS_PER_WINDOW) {
        return FALSE;  // Rate limit exceeded
    }

    // Log this request
    request_log += [requester, llGetUnixTime()];

    return TRUE;
}

// Example usage in link_message handler
link_message(integer sender, integer num, string msg, key id) {
    if (!isRequestAllowed(id)) {
        llRegionSayTo(id, 0, "Rate limit exceeded. Please wait.");
        return;
    }

    // Process request
    handleRequest(msg, id);
}
```

---

## 7. Security Checklist

Use this checklist when implementing security-sensitive features:

### Session Management
- [ ] Sessions use multiple entropy sources (llFrand + llGetUnixTime + UUID)
- [ ] Sessions include context identifiers
- [ ] Sessions have timeouts (typically 60 seconds)
- [ ] Sessions are validated before use
- [ ] Old sessions are cleaned up

### Input Validation
- [ ] All JSON inputs validated with jsonHas()
- [ ] String inputs checked for JSON_INVALID
- [ ] Numeric inputs range-checked
- [ ] Keys validated against NULL_KEY
- [ ] List indices bounds-checked

### Access Control
- [ ] ACL checked before sensitive operations
- [ ] Blacklist checked first (highest priority)
- [ ] Default deny policy (no access unless granted)
- [ ] Owner change triggers script reset
- [ ] Role exclusivity enforced (owner cannot be trustee)

### Rate Limiting
- [ ] Request counting per user/session
- [ ] Time-window based limits (e.g., 10 requests/minute)
- [ ] Old entries cleaned from rate limit log
- [ ] Denial message sent to user
- [ ] DoS testing performed

### Timeout Enforcement
- [ ] Dialog timeouts implemented
- [ ] Session expiration enforced
- [ ] Cleanup functions called on timeout
- [ ] Timeout values documented

---

## 8. Recommendations

### 8.1 Immediate Actions
1. ✅ **Use multi-source entropy** in all session generation
2. ✅ **Implement timeouts** for all interactive sessions
3. ✅ **Validate all inputs** before processing
4. ✅ **Enforce rate limits** on public-facing functions

### 8.2 Long-Term Improvements
1. **Monitor Linden Lab APIs** for cryptographic function additions
2. **Document security assumptions** in code comments
3. **Regular security audits** of session management code
4. **User education** about virtual world security limitations

### 8.3 Documentation
- Add security notes to function headers
- Document entropy sources in session generation
- Include threat model in README
- Reference this document in code comments

---

## 9. References

### LSL Documentation
- [llFrand()](http://wiki.secondlife.com/wiki/LlFrand) - LSL Wiki
- [llGetUnixTime()](http://wiki.secondlife.com/wiki/LlGetUnixTime) - LSL Wiki
- [Security Best Practices](http://wiki.secondlife.com/wiki/Security) - LSL Wiki

### Security Concepts
- **PRNG vs CSPRNG:** [NIST SP 800-90A](https://csrc.nist.gov/publications/detail/sp/800-90a/rev-1/final)
- **Session Management:** [OWASP Session Management](https://owasp.org/www-community/Session_Management_Cheat_Sheet)
- **Entropy Sources:** [Random Number Generation Guide](https://tools.ietf.org/html/rfc4086)

### Related Documents
- `SECURITY_AUDIT_REPORT.md` - Comprehensive security audit
- `STYLE_GUIDE.md` - Code style and naming conventions
- `README.md` - Project overview and architecture

---

## Version History

- **v1.0** (2025-10-29): Initial documentation of LSL random number limitations and mitigations
