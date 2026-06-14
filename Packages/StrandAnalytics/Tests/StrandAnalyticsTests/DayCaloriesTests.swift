import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests Calories.estimateDayCalories — the APPROXIMATE whole-day HR-only energy estimate
/// (Keytel active + Harris–Benedict BMR) that backs DailyMetric.activeKcalEst for BLE-only
/// users. Pure-function tests; no DB. Not cloud/clinical parity. Mirrors the Android
/// DayCaloriesTest vectors value-for-value.
final class DayCaloriesTests: XCTestCase {

    private func hrDay(bpm: Int, n: Int) -> [HRSample] {
        (0..<n).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testDayCaloriesEmptyIsZero() {
        XCTAssertEqual(
            Calories.estimateDayCalories([], profile: UserProfile(), hrmax: 190.0, restingHR: 55.0),
            0.0, accuracy: 1e-12)
    }

    func testDayCaloriesMatchesBoutFirst() {
        // The day estimate must equal the kcal component of the per-bout model for the
        // same samples (it delegates to estimateBoutCalories), so the two never diverge.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let hr = hrDay(bpm: 130, n: 600)  // 10 min above the active threshold
        let day = Calories.estimateDayCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0)
        let bout = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(day, bout, accuracy: 1e-9)
    }

    func testDayCaloriesRestingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        let profile = UserProfile(weightKg: 70, heightCm: 170, age: 30, sex: "nonbinary")
        // activeThreshold = 55 + 0.30*(185-55) = 94 bpm; 60 < 94 (resting), 150 >= 94 (active).
        let restingDay = Calories.estimateDayCalories(hrDay(bpm: 60, n: 3600), profile: profile,
                                                      hrmax: 185.0, restingHR: 55.0)
        let activeDay = Calories.estimateDayCalories(hrDay(bpm: 150, n: 3600), profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        XCTAssertGreaterThan(restingDay, 0.0, "resting day must burn > 0 (BMR floor)")
        XCTAssertGreaterThan(activeDay, restingDay, "active day must exceed resting day")
    }

    func testSparseHRTracksElapsedTimeNotSampleCount() {
        // A 10-minute effort at a steady active HR, sampled two ways over the SAME ~600 s span:
        // densely at 1 Hz, and sparsely at one sample / 10 s (the WHOOP 5/MG case). Energy must
        // track elapsed time, so the sparse estimate lands close to the dense one — NOT ~1/10th
        // of it, as the old one-second-per-sample count produced.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let dense = (0..<600).map { HRSample(ts: $0, bpm: 130) }
        let sparse = stride(from: 0, to: 600, by: 10).map { HRSample(ts: $0, bpm: 130) }
        let denseKcal = Calories.estimateBoutCalories(dense, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let sparseKcal = Calories.estimateBoutCalories(sparse, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(sparseKcal, denseKcal, accuracy: denseKcal * 0.05,
                       "sparse HR must be counted over elapsed time, not undercounted per sample")
        // Teeth: a per-sample count (60 samples) would be ~1/10th of the dense total.
        XCTAssertGreaterThan(sparseKcal, denseKcal * 0.5)
    }

    func testWearGapIsCappedNotCreditedInFull() {
        // Two active samples an hour apart must NOT credit a full hour of active burn — the
        // per-sample interval is capped at mergeGapS (150 s). The pre-gap sample contributes
        // 150 s and the tail 1 s, so the total equals a 151 s continuous equivalent, not 3600 s.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)]
        let cappedEquiv = (0...150).map { HRSample(ts: $0, bpm: 130) }   // 151 s continuous
        let gappedKcal = Calories.estimateBoutCalories(gapped, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let equivKcal = Calories.estimateBoutCalories(cappedEquiv, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(gappedKcal, equivKcal, accuracy: equivKcal * 0.001,
                       "an inter-sample gap must be capped at mergeGapS, not credited in full")
    }

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z).
    private let dayUtc = "2026-01-02"
    private let noonUtc = 1_767_355_200

    private func hr(_ tsOffsetSec: Int, _ bpm: Int) -> HRSample {
        HRSample(ts: noonUtc + tsOffsetSec, bpm: bpm)
    }

    func testAnalyzeDayCaloriesIgnoreAdjacentDayHr() throws {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        let inDay = (0..<600).map { hr($0, 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        let withAdjacent = inDay + (0..<600).map { hr(-36 * 3_600 - $0, 120) }
        let a = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: inDay, profile: UserProfile()).daily.activeKcalEst)
        let b = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: withAdjacent, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(a, b, accuracy: 1e-6, "adjacent-day HR must not change the day's calories")
    }

    func testAnalyzeDayDayHrCoversFullCalendarDay() throws {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full
        // calendar-day HR also has the afternoon. activeKcalEst must use dayHr when supplied,
        // so the full-day total exceeds the clipped night-window total (the undercount fix).
        let nightWindow = (0..<600).map { hr($0, 120) }
        let fullDay = nightWindow + (0..<600).map { hr(3 * 3_600 + $0, 120) }
        let clipped = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, profile: UserProfile()).daily.activeKcalEst)
        let full = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, dayHr: fullDay, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertGreaterThan(full, clipped,
                             "full calendar-day calories must exceed the clipped night-window total")
    }

    func testAnalyzeDayDayHrNilFallsBackToWindowHr() throws {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to
        // passing that same window explicitly as dayHr (the (dayHr ?? hr) fallback).
        let window = (0..<600).map { hr($0, 120) }
        let fallback = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, profile: UserProfile()).daily.activeKcalEst)
        let explicit = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, dayHr: window, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(fallback, explicit, accuracy: 1e-9)
    }
}
