package shadowio

import (
	"crypto/cipher"
	"encoding/binary"
	"io"

	"github.com/metacubex/sing/common/buf"
	N "github.com/metacubex/sing/common/network"
)

const PacketLengthBufferSize = 2

// buf.NewSize uses unmanaged allocations above this size. SS2022 allows a
// 65535-byte payload, whose authentication tag pushes the ciphertext beyond
// that boundary.
const maxManagedBufferSize = 1<<16 - 1

const (
	// Overhead
	// crypto/cipher.gcmTagSize
	// golang.org/x/crypto/chacha20poly1305.Overhead
	Overhead = 16
)

var (
	_ io.Closer        = (*Reader)(nil)
	_ N.ExtendedReader = (*Reader)(nil)
	_ N.ReadWaiter     = (*Reader)(nil)
)

type Reader struct {
	reader          io.Reader
	cipher          cipher.AEAD
	nonce           []byte
	cache           *buf.Buffer
	readWaitOptions N.ReadWaitOptions
	oversizedBuffer []byte
	oversizedIndex  int
	oversizedCached int
}

func NewReader(upstream io.Reader, cipher cipher.AEAD) *Reader {
	return &Reader{
		reader: upstream,
		cipher: cipher,
		nonce:  make([]byte, cipher.NonceSize()),
	}
}

func (r *Reader) Close() error {
	if r.cache != nil {
		r.cache.Release()
		r.cache = nil
	}
	r.oversizedBuffer = nil
	r.oversizedIndex = 0
	r.oversizedCached = 0
	return nil
}

func (r *Reader) ReadFixedBuffer(pLen int) (*buf.Buffer, error) {
	buffer := buf.NewSize(pLen + Overhead)
	_, err := buffer.ReadFullFrom(r.reader, buffer.FreeLen())
	if err != nil {
		buffer.Release()
		return nil, err
	}
	err = r.Decrypt(buffer.Index(0), buffer.Bytes())
	if err != nil {
		buffer.Release()
		return nil, err
	}
	buffer.Truncate(pLen)
	r.cache = buffer
	return buffer, nil
}

func (r *Reader) Decrypt(destination []byte, source []byte) error {
	_, err := r.cipher.Open(destination[:0], r.nonce, source, nil)
	if err != nil {
		return err
	}
	increaseNonce(r.nonce)
	return nil
}

func (r *Reader) Read(p []byte) (n int, err error) {
	if len(p) == 0 {
		return 0, nil
	}
	for {
		if r.oversizedCached > 0 {
			n = r.readOversizedCache(p)
			if n > 0 {
				return
			}
		}
		if r.cache != nil {
			if r.cache.IsEmpty() {
				r.cache.Release()
				r.cache = nil
			} else {
				n = copy(p, r.cache.Bytes())
				if n > 0 {
					r.cache.Advance(n)
					return
				}
			}
		}
		r.cache, err = r.readBuffer()
		if err != nil {
			return
		}
	}
}

func (r *Reader) ReadBuffer(buffer *buf.Buffer) error {
	if buffer.FreeLen() == 0 {
		return io.ErrShortBuffer
	}
	var err error
	for {
		if r.oversizedCached > 0 {
			n := r.readOversizedCache(buffer.FreeBytes())
			if n > 0 {
				buffer.Truncate(n)
				return nil
			}
		}
		if r.cache != nil {
			if r.cache.IsEmpty() {
				r.cache.Release()
				r.cache = nil
			} else {
				n := copy(buffer.FreeBytes(), r.cache.Bytes())
				if n > 0 {
					buffer.Truncate(n)
					r.cache.Advance(n)
					return nil
				}
			}
		}
		r.cache, err = r.readBuffer()
		if err != nil {
			return err
		}
	}
}

func (r *Reader) InitializeReadWaiter(options N.ReadWaitOptions) (needCopy bool) {
	r.readWaitOptions = options
	return options.NeedHeadroom()
}

func (r *Reader) WaitReadBuffer() (buffer *buf.Buffer, err error) {
	for {
		if r.oversizedCached > 0 {
			buffer = r.readWaitOptions.NewBuffer()
			n := r.readOversizedCache(buffer.FreeBytes())
			if n == 0 {
				buffer.Release()
				return nil, io.ErrShortBuffer
			}
			buffer.Truncate(n)
			r.readWaitOptions.PostReturn(buffer)
			return buffer, nil
		}
		if r.readWaitOptions.NeedHeadroom() {
			if r.cache != nil {
				if r.cache.IsEmpty() {
					r.cache.Release()
					r.cache = nil
				} else {
					buffer = r.readWaitOptions.NewBuffer()
					var n int
					n, err = buffer.Write(r.cache.Bytes())
					if err != nil {
						buffer.Release()
						return
					}
					buffer.Truncate(n)
					r.cache.Advance(n)
					r.readWaitOptions.PostReturn(buffer)
					return
				}
			}
		} else if r.cache != nil {
			cache := r.cache
			r.cache = nil
			return cache, nil
		}
		r.cache, err = r.readBuffer()
		if err != nil {
			return nil, err
		}
	}
}

func (r *Reader) readBuffer() (*buf.Buffer, error) {
	buffer := buf.NewSize(PacketLengthBufferSize + Overhead)
	_, err := buffer.ReadFullFrom(r.reader, buffer.FreeLen())
	if err != nil {
		buffer.Release()
		return nil, err
	}
	_, err = r.cipher.Open(buffer.Index(0), r.nonce, buffer.Bytes(), nil)
	if err != nil {
		buffer.Release()
		return nil, err
	}
	increaseNonce(r.nonce)
	length := int(binary.BigEndian.Uint16(buffer.To(PacketLengthBufferSize)))
	buffer.Release()
	ciphertextSize := length + Overhead
	if ciphertextSize > maxManagedBufferSize {
		err = r.readOversizedBuffer(ciphertextSize)
		return nil, err
	}
	buffer = buf.NewSize(ciphertextSize)
	_, err = buffer.ReadFullFrom(r.reader, buffer.FreeLen())
	if err != nil {
		buffer.Release()
		return nil, err
	}
	_, err = r.cipher.Open(buffer.Index(0), r.nonce, buffer.Bytes(), nil)
	if err != nil {
		buffer.Release()
		return nil, err
	}
	increaseNonce(r.nonce)
	buffer.Truncate(length)
	return buffer, nil
}

func (r *Reader) readOversizedBuffer(ciphertextSize int) error {
	if r.oversizedBuffer == nil {
		r.oversizedBuffer = make([]byte, maxManagedBufferSize+Overhead)
	}
	ciphertext := r.oversizedBuffer[:ciphertextSize]
	_, err := io.ReadFull(r.reader, ciphertext)
	if err != nil {
		return err
	}
	plaintext, err := r.cipher.Open(ciphertext[:0], r.nonce, ciphertext, nil)
	if err != nil {
		return err
	}
	increaseNonce(r.nonce)
	r.oversizedIndex = 0
	r.oversizedCached = len(plaintext)
	return nil
}

func (r *Reader) readOversizedCache(destination []byte) int {
	n := copy(destination, r.oversizedBuffer[r.oversizedIndex:r.oversizedIndex+r.oversizedCached])
	r.oversizedIndex += n
	r.oversizedCached -= n
	if r.oversizedCached == 0 {
		r.oversizedIndex = 0
	}
	return n
}
