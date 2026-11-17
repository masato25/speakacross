import Testing
@testable import SpeakAcrossCore

@Test func recoveryPolicyUsesConfiguredBackoffAndCapsAttempts() {
    let policy = SessionRecoveryPolicy(
        maxAttempts: 4,
        delaysMilliseconds: [100, 200]
    )

    #expect(policy.delayMilliseconds(forAttempt: 1) == 100)
    #expect(policy.delayMilliseconds(forAttempt: 2) == 200)
    #expect(policy.delayMilliseconds(forAttempt: 3) == 200)
    #expect(policy.delayMilliseconds(forAttempt: 4) == 200)
    #expect(policy.delayMilliseconds(forAttempt: 5) == nil)
}

@Test func recoveryPolicyRejectsAttemptZero() {
    let policy = SessionRecoveryPolicy()
    #expect(policy.delayMilliseconds(forAttempt: 0) == nil)
}
