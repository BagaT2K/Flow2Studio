# OEM Lofree 0.14 — Flow 2 68 / 84 / 100

Official announcement: https://www.reddit.com/r/Lofree/comments/1nk4hy8/greetingseveryone_flow2_software_update_is_here/
Official linked archive: https://www.dropbox.com/scl/fo/a7zu8onrpgeuapown41qo/AMjPN18WHlTjf6q6UjqSaRE?rlkey=7xukp2egjgvg3ap8sieil8nmi&st=jntlv12t&dl=0

Original files in FLOW2-MacOS-TOOL (Wired mode):
- 68: oe928_via_68-key keyboard_v14.hex — SHA256 4ec9c19c906901c491bade1c26ec908538ca792e60a3c378a6df4414505f9cf3
- 84: oe927_via_84-key keyboard_v14.hex — SHA256 6c3828b4371629c70d715e95627bb59441d7775f1ff04fd9d81c146ff4ca6eea
- 100: oe926_via_100-key keyboard_v14.hex — SHA256 5586079676271b13abc74b8cb04ae35c32fc9c3bf5fa9d06ff3fc45c1aa65594

Factory binaries are normalized full 262144-byte images, with the official HEX body
and a zero tail. Their hashes are pinned in firmware/source-pins.json and the model
catalogs. USB VID 388d, PIDs 0001/0002/0003, bcdDevice 0014. Flow 2 for Mac is excluded.
Radio firmware is unchanged. These are normalized images, not physical factory dumps.
Studio 0.9 changes the public version identity from development 3.19; behavior is preserved.
Physical validation of the new 0.9 build remains pending.
