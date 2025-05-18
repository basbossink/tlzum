const std = @import("std");

const clock_in: u8 = 'i';
const clock_out: u8 = 'o';
const comment_start: u8 = '#';
const newline: u8 = '\n';
const value_undefined = "⊥";
const hline = "─";

const timelog_env_name = "TIMELOG";

const ExitCodes = enum { success, timelog_env_var_not_defined, timelog_file_not_found };

//           1         2
// 012345678901234567890123456
// i 2022/04/22 21:33:23 e:fc:fred
const line_length: usize = 20;
const date_time_length: usize = line_length - 1;
const workday_secs: i64 = 8 * std.time.s_per_hour;

const Error = error{
    IoErrorWhileReadingTimelog,
    InvalidDateTimeFormat,
    ClockOutBeforeClockIn,
    UnexpectedClockIn,
    UnexpectedClockOut,
    Oops,
};

const ParseOrIoError = Error || std.fmt.ParseIntError;

const Expecting = enum {
    in,
    out,
};

const StateWithCurrent = struct {
    state: Expecting,
    current: u8,
};

pub fn main() !void {
    var buffer: [512 * 1024]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = gpa.allocator();

    const timelog = try open_timelog(allocator);
    defer timelog.close();

    var buffered = std.io.bufferedReaderSize(256 * 1024, timelog.reader());
    const reader = buffered.reader();
    var buff = [_]u8{0} ** 255;

    var line_num: usize = 0;
    var first_punchin_today: ?Time = null;
    var last_punchin: ?DateTime = null;
    var last_punchout: ?DateTime = null;
    var days_worked: u16 = 0;
    var total_worked: i64 = 0;
    var worked_today: i64 = 0;

    const now = std.time.timestamp();
    const today = now - @rem(now, std.time.s_per_day);
    const today_days_since_epoch = @divExact(today, std.time.s_per_day);
    var previous_date: ?Date = null;
    var segment = [_]u8{0} ** date_time_length;
    var first_char = [_]u8{0};
    var clockin: ?DateTime = null;
    var state = Expecting.in;
    while (true) {
        const read = reader.readAll(&first_char) catch {
            std.log.err("Error while reading from time log file", .{});
            return Error.IoErrorWhileReadingTimelog;
        };
        if (read < 1) {
            std.log.debug("read {d} bytes, stopping", .{read});
            break;
        }
        line_num += 1;
        if (first_char[0] == comment_start) {
            reader.skipUntilDelimiterOrEof(newline) catch {
                std.log.err("Error while reading from time log file, at line {d}", .{line_num});
                return Error.IoErrorWhileReadingTimelog;
            };
            continue;
        }
        // skip space following i or o.
        reader.skipBytes(1, .{}) catch {
            std.log.err("Error while reading from time log file, at line {d}", .{line_num});
            return Error.IoErrorWhileReadingTimelog;
        };
        const read_2 = reader.readAll(&segment) catch {
            std.log.err("Error while reading from time log file, at line {d}", .{line_num});
            return Error.IoErrorWhileReadingTimelog;
        };
        if (read_2 < date_time_length) {
            std.log.err("read {d} bytes which is less than timestamp, stopping", .{read_2});
            break;
        }
        // Read the the timestamp only, discard the rest of the line
        const current = try parse_date_time(&segment);
        reader.skipUntilDelimiterOrEof(newline) catch {
            std.log.err("Error while reading from time log file, at line {d}", .{line_num});
            return Error.IoErrorWhileReadingTimelog;
        };
        const current_action = first_char[0];
        std.log.debug("current actions {0} state {1}", .{ current_action, state });

        if (state == Expecting.in and current_action == clock_in) {
            if (previous_date) |prev| {
                const date_change = !std.meta.eql(prev, current.date);
                if (date_change) {
                    worked_today = 0;
                    days_worked += 1;
                    if (today_days_since_epoch == days_since_epoch(current.date) and first_punchin_today == null) {
                        first_punchin_today = current.time;
                    }
                }
            } else {
                worked_today = 0;
                days_worked += 1;
                if (today_days_since_epoch == days_since_epoch(current.date) and first_punchin_today == null) {
                    first_punchin_today = current.time;
                }
            }
            previous_date = current.date;
            clockin = current;
            if (last_punchin) |lpi| {
                last_punchin = max(lpi, current);
            } else {
                last_punchin = current;
            }
            std.log.debug("finished processing clock in {d}", .{line_num});
            state = Expecting.out;
        } else if (state == Expecting.out and current_action == clock_out) {
            if (clockin) |ci| {
                if (date_time_lt(current, ci)) {
                    std.log.err("Clock out time before clock in time on line {d}", .{line_num});
                    return Error.ClockOutBeforeClockIn;
                }
                const clocked = in_year_diff(current, ci);
                if (today_days_since_epoch == days_since_epoch(current.date)) {
                    worked_today += clocked;
                }
                total_worked += clocked;
            } else {
                std.log.err("Inconsistent state expecting clock out but clock in is null on line {d}", .{line_num});
                return Error.Oops;
            }
            if (last_punchout) |lpa| {
                last_punchout = max(lpa, current);
            } else {
                last_punchout = current;
            }
            std.log.debug("finished processing clock out {d}", .{line_num});
            state = Expecting.in;
        } else if (state == Expecting.in and current_action == clock_out) {
            std.log.err("Unexpected clock out on line {d}", .{line_num});
            return Error.UnexpectedClockOut;
        } else {
            std.log.err("Unexpected clock in on line {d}", .{line_num});
            return Error.UnexpectedClockIn;
        }
        std.log.debug("finished {d}", .{line_num});
    }
    const current_clocked_in = state == Expecting.out;
    if (current_clocked_in) {
        if (clockin) |ci| {
            const clock_in_secs_since_epoch = today_days_since_epoch + secs_since_day_start(ci.time);
            if (now < clock_in_secs_since_epoch) {
                std.log.err("now is before clock in time on line {d}", .{line_num});
            }
            const clocked = now - clock_in_secs_since_epoch;
            if (today_days_since_epoch == days_since_epoch(ci.date)) {
                worked_today += clocked;
            }
            total_worked += clocked;
        } else {
            std.log.err("Inconsistent state expecting clock out but clock in is null on line {d}", .{line_num});
            return Error.Oops;
        }
    }
    const avg_worked = @divFloor(total_worked, days_worked);
    const total_worked_until_prev = total_worked - worked_today;
    const overtime = if (days_worked > 0)
        total_worked_until_prev - (days_worked - 1) * workday_secs
    else
        0;
    const still_to_work_8 = workday_secs - worked_today;
    const still_to_work = still_to_work_8 - overtime;
    const time_to_leave = if (current_clocked_in) (today + still_to_work) else null;
    const time_to_leave_8 = if (current_clocked_in) (today + still_to_work_8) else null;
    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("{s:─<71}\n", .{hline});
    try stdout.print("{s:─<71}\n", .{hline});
    try stdout.print("{0s: <45}{1s}\n", .{ "First punch in today:", try format_nullable_time(first_punchin_today, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Last punch in:", try format_nullable_date_time(last_punchin, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Last punch out:", try format_nullable_date_time(last_punchout, &buff) });
    try stdout.print("{s:─<71}\n", .{hline});
    try stdout.print("{0s: <45}{1s}\n", .{ "Average number of hours worked per workday:", try format_as_hours_minutes(avg_worked, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Total time worked:", try format_as_hours_minutes(total_worked, &buff) });
    try stdout.print("{0s: <45}{1d}\n", .{ "Number of days worked:", days_worked });
    try stdout.print("{s:─<71}\n", .{hline});
    try stdout.print("{0s: <45}{1s}\n", .{ "Cumulative overtime per yesterday:", try format_as_hours_minutes(overtime, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Worked today:", try format_as_hours_minutes(worked_today, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Still to work (8hrs):", try format_as_hours_minutes(still_to_work_8, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Still to work:", try format_as_hours_minutes(still_to_work, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Time to leave (8hrs):", try format_as_hours_minutes(time_to_leave_8, &buff) });
    try stdout.print("{0s: <45}{1s}\n", .{ "Time to leave:", try format_as_hours_minutes(time_to_leave, &buff) });
    try stdout.print("{s:─<71}\n", .{hline});
    try stdout.print("{s:─<71}\n", .{hline});

    try bw.flush();
}

fn open_timelog(allocator: std.mem.Allocator) !std.fs.File {
    const path = std.process.getEnvVarOwned(allocator, timelog_env_name) catch {
        std.log.err("Could not read environment variable {s}", .{timelog_env_name});
        std.process.exit(@intFromEnum(ExitCodes.timelog_env_var_not_defined));
    };
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch {
        std.log.err("Could not open time log file {s}", .{path});
        std.process.exit(@intFromEnum(ExitCodes.timelog_file_not_found));
    };
    return file;
}

const days_per_month_non_leap = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const days_per_month_leap = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

const Date = struct { y: u16, m: u8, d: u8 };

const Time = struct {
    h: u8,
    m: u8,
    s: u8,
};

const DateTime = struct {
    date: Date,
    time: Time,
};

//           1         2
// 012345678901234567890123456
// 2022/04/22 21:33:23 e:fc:fred

fn parse_date_time(buff: []const u8) ParseOrIoError!DateTime {
    std.log.debug("parsing date time from: {0s} with length {1d}", .{ buff, buff.len });
    const base = 10;
    const year = try std.fmt.parseUnsigned(u16, buff[0..4], base);
    const month = try std.fmt.parseUnsigned(u8, buff[5..7], base);
    const day = try std.fmt.parseUnsigned(u8, buff[8..10], base);
    const h = try std.fmt.parseUnsigned(u8, buff[11..13], base);
    const m = try std.fmt.parseUnsigned(u8, buff[14..16], base);
    const s = try std.fmt.parseUnsigned(u8, buff[17..19], base);

    return DateTime{ .date = Date{ .y = year, .m = month, .d = day }, .time = Time{ .h = h, .m = m, .s = s } };
}

test "parse date time should be correct for date times without zeroes" {
    const actual = try parse_date_time("2004/12/24 15:13:12");
    const expected = DateTime{ .date = Date{ .y = 2004, .m = 12, .d = 24 }, .time = Time{ .h = 15, .m = 13, .s = 12 } };
    try std.testing.expectEqual(expected, actual);
}

test "parse date time should be correct for date times with zeroes" {
    const actual = try parse_date_time("2004/01/01 00:23:02");
    const expected = DateTime{ .date = Date{ .y = 2004, .m = 1, .d = 1 }, .time = Time{ .h = 0, .m = 23, .s = 2 } };
    try std.testing.expectEqual(actual, expected);
}

test "is leap year should be correct" {
    try std.testing.expect(is_leap_year(2000));
    try std.testing.expect(!is_leap_year(1900));
    try std.testing.expect(is_leap_year(2024));
    try std.testing.expect(is_leap_year(4));
    try std.testing.expect(!is_leap_year(7));
    try std.testing.expect(is_leap_year(2004));
    try std.testing.expect(!is_leap_year(1999));
}

fn is_leap_year(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn day_number(date: Date) u16 {
    const days_per_month = if (is_leap_year(date.y)) days_per_month_leap else days_per_month_non_leap;
    var i: u8 = 0;
    var number: u16 = 0;
    if (date.m == 1) {
        return date.d;
    }
    while (i < date.m - 1) {
        number += days_per_month[i];
        i += 1;
    }
    return number + date.d;
}

test "day number should be correct" {
    try std.testing.expectEqual(1, day_number(Date{ .y = 1, .m = 1, .d = 1 }));
    try std.testing.expectEqual(44, day_number(Date{ .y = 1, .m = 2, .d = 13 }));
    try std.testing.expectEqual(31 + 29 + 13, day_number(Date{ .y = 4, .m = 3, .d = 13 }));
}

fn year_start_days_since_epoch(year: u16) u32 {
    var running_year: u16 = 1970;
    var days: u32 = 0;
    while (running_year < year) {
        days += if (is_leap_year(running_year)) 366 else 365;
        running_year += 1;
    }
    return days;
}

test "year start days since epoch should be correct" {
    try std.testing.expectEqual(0, year_start_days_since_epoch(1970));
    try std.testing.expectEqual(365, year_start_days_since_epoch(1971));
    try std.testing.expectEqual(365 + 365 + 366, year_start_days_since_epoch(1973));
}

fn days_since_epoch(date: Date) u32 {
    return year_start_days_since_epoch(date.y) + day_number(date);
}

fn date_time_lt(lhs: DateTime, rhs: DateTime) bool {
    if (lhs.date.y < rhs.date.y) {
        return true;
    }
    if (day_number(lhs.date) < day_number(rhs.date)) {
        return true;
    }
    return secs_since_day_start(lhs.time) < secs_since_day_start(rhs.time);
}

fn max(lhs: DateTime, rhs: DateTime) DateTime {
    return if (date_time_lt(lhs, rhs)) rhs else lhs;
}

test "date time less than should be correct" {
    const t1 = DateTime{ .date = Date{ .y = 1, .m = 1, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 1 } };
    try std.testing.expect(!date_time_lt(t1, t1));
    const t2 = DateTime{ .date = Date{ .y = 1, .m = 1, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 2 } };
    try std.testing.expect(date_time_lt(t1, t2));
    try std.testing.expect(!date_time_lt(t2, t1));
    const t3 = DateTime{ .date = Date{ .y = 1, .m = 2, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 2 } };
    try std.testing.expect(date_time_lt(t1, t3));
    try std.testing.expect(!date_time_lt(t3, t2));
    try std.testing.expect(!date_time_lt(t3, t1));
    const t4 = DateTime{ .date = Date{ .y = 2, .m = 1, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 1 } };
    try std.testing.expect(date_time_lt(t1, t4));
    try std.testing.expect(date_time_lt(t3, t4));
    const t5 = DateTime{ .date = Date{ .y = 2016, .m = 7, .d = 4 }, .time = Time{ .h = 7, .m = 45, .s = 33 } };
    const t6 = DateTime{ .date = Date{ .y = 2016, .m = 7, .d = 4 }, .time = Time{ .h = 12, .m = 9, .s = 36 } };
    try std.testing.expect(date_time_lt(t5, t6));
    try std.testing.expect(!date_time_lt(t6, t5));
}

test "date time max should be correct" {
    const t1 = DateTime{ .date = Date{ .y = 1, .m = 1, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 1 } };
    const t2 = DateTime{ .date = Date{ .y = 1, .m = 1, .d = 1 }, .time = Time{ .h = 1, .m = 1, .s = 2 } };
    try std.testing.expectEqual(t2, max(t1, t2));
    try std.testing.expectEqual(t2, max(t2, t1));
}

fn in_year_diff(lhs: DateTime, rhs: DateTime) i64 {
    return (@as(i64, day_number(lhs.date) - day_number(rhs.date)) * std.time.s_per_day) +
        (secs_since_day_start(lhs.time) - secs_since_day_start(rhs.time));
}

fn secs_since_day_start(time: Time) i64 {
    return @as(i64, time.h) * std.time.s_per_hour + @as(i64, time.m) * std.time.s_per_min + time.s;
}

test "seconds since dat start should be correct" {
    const t1 = Time{ .h = 0, .m = 0, .s = 37 };
    try std.testing.expectEqual(37, secs_since_day_start(t1));

    const t2 = Time{ .h = 0, .m = 37, .s = 37 };
    try std.testing.expectEqual(2257, secs_since_day_start(t2));

    const t3 = Time{ .h = 1, .m = 37, .s = 37 };
    try std.testing.expectEqual(5857, secs_since_day_start(t3));
}

fn format_nullable_time(time: ?Time, buff: []u8) ![]const u8 {
    if (time) |t| {
        return try std.fmt.bufPrint(buff, "{0d:02}:{1d:02}:{2d:02}", .{ t.h, t.m, t.s });
    } else {
        return value_undefined;
    }
}

test "format nullable time should be correct" {
    var buff = [_]u8{0} ** 255;
    const t1: ?Time = null;
    try std.testing.expectEqualStrings(value_undefined, try format_nullable_time(t1, &buff));

    const t2: ?Time = Time{ .h = 1, .m = 1, .s = 1 };
    try std.testing.expectEqualStrings("01:01:01", try format_nullable_time(t2, &buff));

    const t3: ?Time = Time{ .h = 23, .m = 12, .s = 7 };
    try std.testing.expectEqualStrings("23:12:07", try format_nullable_time(t3, &buff));
}

fn format_as_hours_minutes(secs: ?i64, buff: []u8) ![]const u8 {
    if (secs) |s| {
        const hours = @abs(@divTrunc(s, std.time.s_per_hour));
        const minutes = @abs(@divTrunc(@rem(s, std.time.s_per_hour), std.time.s_per_min));
        if (s < 0) {
            return try std.fmt.bufPrint(buff, "-{0d: <4} hours, {1d: <5} minutes", .{ hours, minutes });
        }
        return try std.fmt.bufPrint(buff, "{0d: <5} hours, {1d: <5} minutes", .{ hours, minutes });
    } else {
        return value_undefined;
    }
}

test "format as hours minutes of nullable number of seconds should be correct" {
    var buff = [_]u8{0} ** 255;
    const t1: ?i64 = null;
    const actual_1 = try format_as_hours_minutes(t1, &buff);
    try std.testing.expectEqualStrings(value_undefined, actual_1);

    const t2: ?i64 = 3600 + 3600 + 72;
    const actual_2 = try format_as_hours_minutes(t2, &buff);
    try std.testing.expectEqualStrings("2     hours, 1     minutes", actual_2);

    const t3: ?i64 = 3600 + 3600 + 122;
    const actual_3 = try format_as_hours_minutes(t3, &buff);
    try std.testing.expectEqualStrings("2     hours, 2     minutes", actual_3);

    const t4: ?i64 = -3600 - 3600 - 122;
    const actual_4 = try format_as_hours_minutes(t4, &buff);
    try std.testing.expectEqualStrings("-2    hours, 2     minutes", actual_4);
}

fn format_nullable_date_time(time: ?DateTime, buff: []u8) ![]const u8 {
    if (time) |t| {
        return try std.fmt.bufPrint(buff, "{3d:02}:{4d:02}:{5d:02}{6s: <8}{0d}/{1d:02}/{2d:02}", .{ t.date.y, t.date.m, t.date.d, t.time.h, t.time.m, t.time.s, " " });
    } else {
        return value_undefined;
    }
}

test "format nullable date time  should be correct" {
    var buff = [_]u8{0} ** 255;
    const t1: ?DateTime = null;
    const actual_1 = try format_nullable_date_time(t1, &buff);
    try std.testing.expectEqualStrings(value_undefined, actual_1);

    const t2: ?DateTime = DateTime{ .date = Date{ .y = 2000, .m = 12, .d = 31 }, .time = Time{ .h = 23, .m = 23, .s = 23 } };
    const actual_2 = try format_nullable_date_time(t2, &buff);
    try std.testing.expectEqualStrings("23:23:23        2000/12/31", actual_2);

    const t3: ?DateTime = DateTime{ .date = Date{ .y = 2000, .m = 2, .d = 1 }, .time = Time{ .h = 2, .m = 3, .s = 5 } };
    const actual_3 = try format_nullable_date_time(t3, &buff);
    try std.testing.expectEqualStrings("02:03:05        2000/02/01", actual_3);
}
