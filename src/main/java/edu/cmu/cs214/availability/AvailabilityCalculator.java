package edu.cmu.cs214.availability;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * Computes when a room is free. Given the day's business hours and the room's
 * bookings, it returns the free gaps: the parts of the business day not covered
 * by any booking.
 */
public class AvailabilityCalculator {

    /**
     * Returns the free gaps in {@code [dayStart, dayEnd)} not covered by any booking,
     * in order. Bookings may be unsorted, may overlap each other, and may extend
     * outside business hours; they are clipped to the day and merged.
     */
    public List<TimeInterval> freeSlots(int dayStart, int dayEnd, List<TimeInterval> bookings) {
        List<TimeInterval> clipped = new ArrayList<>();
        for (TimeInterval b : bookings) {
            int s = Math.max(b.start(), dayStart);
            int e = Math.min(b.end(), dayEnd);
            if (s < e) {
                clipped.add(new TimeInterval(s, e));
            }
        }
        clipped.sort(Comparator.comparingInt(TimeInterval::start));

        List<TimeInterval> free = new ArrayList<>();
        int cursor = dayStart;
        for (TimeInterval b : clipped) {
            if (b.start() > cursor) {
                free.add(new TimeInterval(cursor, b.start()));
            }
            cursor = Math.max(cursor, b.end());
        }
        if (cursor < dayEnd) {
            free.add(new TimeInterval(cursor, dayEnd));
        }
        return free;
    }
}
