fn main() {
    let mut buffer = itoa::Buffer::new();
    let rendered = buffer.format(42);
    let needle = memchr::memchr(b'x', b"xyz");

    assert_eq!(rendered, "42");
    assert_eq!(needle, Some(0));
}
