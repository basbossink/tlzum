<div align="center">
<h1 align="center">tlzum</h1>
<br />
<img alt="License: BSD-2-Clause" src="https://img.shields.io/badge/License-BSD-blue" /><br>
<br>
An Emacs timelog summarizer written in Zig.
</div>

***
This small application takes a timelog file as created by the
[Emacs](https://www.gnu.org/software/emacs/) `M-x timeclock-in` and `M-x
timeclock-out` commands and calculates summary information from this timelog.
The format is a line-based text file consisting of lines with the following
format:

```
i YYYY/MM/dd HH:mm:ss <some description of the item being clocked>
o YYYY/MM/dd HH:mm:ss [<an optional reason for stopping the item being clocked>]
```

To create such a file using Emacs is not required of course. Currently I use
these simple `fish` functions bound to specific key in my window manager of
choice:

```fish
function clock-in
    date +"i %Y/%m/%d %H:%M:%S" >> $TIMELOG
end

function clock-out
    date +"o %Y/%m/%d %H:%M:%S" >> $TIMELOG
end
```

## Provided summary

`tlzum` provides the following summary information:

- The number of days worked; the number of unique dates that have a clock in
  (`i`) event.
- The total number of hours and minutes clocked.
- The average number of hours and minutes clocked per day.
- The cumulative overtime up to but not including the last date there was a
  clock in, typically yesterday.
- The first clock in of today.
- The last clock in.
- The last clock out.
- The number of hours worked today.
- The number of hours and minutes still to work today, taking overtime into
  account.
- The number of hours and minutes still to work today, based on an 8 hour
  workday today.
- The time to leave, taking overtime into account.
- The time to leave, based on an 8 hour workday today.

`tlzum` assumes an 8 hour workday, any time allotted for lunch breaks is not
taken into account for now.

Furthermore to avoid any extra dependencies date time calculations are very
primitive and expect the timelog file to only contain data for the current year.

The excellent [ledger-cli](https://www.ledger-cli.org/),
can create some nice  reports for the timelog as well, I
strongly recommend using it, refer to the  [documentation
here](https://www.ledger-cli.org/3.0/doc/ledger3.html#Time-Keeping).
This tool is merely a [Zig](https://ziglang.org/) learning project,
and a reimplementation of the [fish](https://fishshell.com/)
and [awk](https://en.wikipedia.org/wiki/AWK) scripts in my
[dot-files](https://github.com/basbossink/dot-files-via-chezmoi).

### Installation

Currently only building from source is supported which requires Zig >= 0.13.0.

```
git clone https://github.com/basbossink/tlzum
cd tlzum
zig build-exe -femit-bin=zig-out/tlzum \
    --name tlzum \
    -O ReleaseFast \
    -fstrip \
    -fsingle-threaded \
    -fomit-frame-pointer \
    -flto \
    -static \
    src/main.zig
```

Or if you have [just](https://github.com/casey/just) installed, run the `just`
command in the project root.

After running these commands the binary can be found as `zig-out/tlzum` and can
be placed anywhere in your `$PATH`.

### Usage

To set the location of your timelog file the `TIMELOG` environment variable
needs to be set, either by prefixing it to the command invocation or by setting
in in your profile.

```
TIMELOG=$HOME/.timelog tlzum
```

### License

This project is licensed under the BSD-2-Clause license. See the
[LICENSE](LICENSE) for details.
