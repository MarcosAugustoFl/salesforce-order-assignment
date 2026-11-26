/**
 * Enqueues a follow-up Queueable (next page, next batch, or a retry after a delay).
 *
 * Apex tests cannot chain Queueables (a job enqueued from a running job throws), so under test the job is
 * captured instead. Tests then assert on what would have run next, and can execute it directly.
 */
public inherited sharing class QueueableChain {
    @TestVisible
    private static List<Queueable> captured = new List<Queueable>();

    public static void enqueue(Queueable job, Integer delayMinutes) {
        if (Test.isRunningTest()) {
            captured.add(job);
            return;
        }
        System.enqueueJob(job, Math.max(0, Math.min(delayMinutes, 10))); // platform allows 0-10 minutes
    }

    /** Minutes to wait for a Retry-After given in seconds (rounded up, at least one minute). */
    public static Integer minutesFor(Integer retryAfterSeconds) {
        if (retryAfterSeconds == null || retryAfterSeconds <= 0) {
            return 1;
        }
        return Math.max(1, (Integer) Math.ceil(retryAfterSeconds / 60.0));
    }
}
