# HeadEQ

Menu bar app: system-wide 10-band parametric EQ (frequency, gain, Q per band) with per-output-device profiles.

```bash
./build.sh   # test, build, sign, install to ~/Applications, launch
```

How it works: a Core Audio process tap (macOS 14.4+) captures all system audio and mutes the original;
a private aggregate device (tap + current default output) runs it through a vDSP biquad cascade
(`Sources/EQCore`) and plays it on the output. No audio driver needed. First run asks for
"System Audio Recording" permission.

Profiles are stored per output device UID, so plugging in headphones switches to their profiles.
