cimport cython

import math

from libc.stdlib cimport malloc, free
from libc.math cimport log, ceil
from libc.stdio cimport printf, FILE, fopen, fwrite, fclose, fread
from cpython.mem cimport PyMem_Malloc, PyMem_Free

DEF LN2_SQUARED = 0.480453013918201  # ln(2)^2
DEF LN2 = 0.693147180559945  # ln(2)

cdef extern from "stdlib.h" nogil:
    long long int llabs(long long int j)

cdef extern from "MurmurHash3.h":
    void MurmurHash3_x86_32(void *key, int len, unsigned long seed, void *out)
    void MurmurHash3_x86_128(void *key, int len, unsigned long seed, void *out)
    void MurmurHash3_x64_128 (void *key, int len, unsigned long seed, void *out)

cdef class BloomFilter:

    cdef unsigned int nbr_slices
    cdef unsigned long long _bucket_indexes[1000]
    cdef unsigned long long nbr_bits
    cdef unsigned char *bitarray
    cdef unsigned long long nbr_bytes
    cdef unsigned long long capacity
    cdef unsigned long long bits_per_slice
    cdef double error_rate
    cdef unsigned long long _count

    def __cinit__(self, capacity, error_rate):
        self.capacity = capacity
        self.error_rate = error_rate
        self._initialize_parameters()
        self._count = 0
        self.bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))
        if not self.bitarray:
            raise MemoryError("Unable to allocate memory for BloomFilter")
        else:
            self._initialize_bitarray()

    def _initialize_parameters(self):
        self.nbr_slices = int(math.floor(math.log(1.0 / self.error_rate, 2.0)))
        self.bits_per_slice = int(math.ceil(
                self.capacity * abs(math.log(self.error_rate)) /
                (self.nbr_slices * (math.log(2) ** 2))))

        self.nbr_bits = self.nbr_slices * self.bits_per_slice

        for i in range(self.nbr_slices):
            self._bucket_indexes[i]=0

        # Initializing the bitarray
        if self.nbr_bits % 8:
            self.nbr_bytes = (self.nbr_bits / 8) + 1
        else:
            self.nbr_bytes = self.nbr_bits / 8

    def _set_capacity(self, capacity):
        self.capacity = capacity

    def _get_capacity(self):
        return self.capacity

    def _set_error_rate(self, error_rate):
        self.error_rate = error_rate

    def _get_error_rate(self):
        return self.error_rate

    @property
    def _snapshot_header(self):
        return self.capacity, self.error_rate

    def _save_snapshot(self,  char* filename):
        """Save bitarray into a simple binary file."""
        f = fopen(filename, 'w')
        # Write the header
        fwrite(&(self.capacity), sizeof(unsigned long long), 1, f)
        fwrite(&(self.error_rate), sizeof(double), 1, f)
        fwrite(&(self._count), sizeof(unsigned long long), 1, f)

        # Write the data
        fwrite(self.bitarray, 1, self.nbr_bytes, f)
        fclose(f)

    def _read_snapshot(self, char* filename):
        """Restore the BF using a binary dump.

        This method will overwrite the BF parameters with those in the file's header.
        """
        f = fopen(filename, "r")
        fread(&(self.capacity), sizeof(unsigned long long), 1, f)
        fread(&(self.error_rate), sizeof(double), 1, f)
        fread(&(self._count), sizeof(unsigned long long), 1, f)

        self._initialize_parameters()
        self.bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))
        fread(self.bitarray, 1, self.nbr_bytes, f)
        fclose(f)

    def _union_bf_from_file(self, char* filename):
        """Union the current BF with other BF saved in snapshot.

        Always read first snapshot using _read_snapshot() before unioning in order
        to retinitialize the parameters correctly.
        """
        cdef unsigned long long new_capacity
        cdef unsigned long long new_count
        cdef double new_error_rate

        f = fopen(filename, "r")
        fread(&(new_capacity), sizeof(unsigned long long), 1, f)
        fread(&(new_error_rate), sizeof(double), 1, f)
        fread(&(new_count), sizeof(unsigned long long), 1, f)

        if (new_capacity != self.capacity) or (new_error_rate != self.error_rate):
            return False

        self._initialize_parameters()
        temp_bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))

        fread(temp_bitarray, 1, self.nbr_bytes, f)
        fclose(f)

        self._bitarray_or(self.bitarray, temp_bitarray)
        PyMem_Free(temp_bitarray)

    def initialize_bitarray(self):
        self._count = 0
        self._initialize_bitarray()

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef void _initialize_bitarray(self):
        for i in range(self.nbr_bytes):
            self.bitarray[i] = 0

    cdef void _bitarray_or(self, unsigned char* bitarray, unsigned char* other_bitarray):
        for i in range(self.nbr_bytes):
            bitarray[i] = bitarray[i] | other_bitarray[i]

    def union(self, BloomFilter other):
        self._bitarray_or(self.bitarray, other.bitarray)

    def __repr__(self):
        return """Capacity: %s\nError rate: %s\nnbr. bits: %s\nnbr. bytes: %s\nnbr. hashes: %s """ \
                % (self.capacity, self.error_rate, self.nbr_bits, self.nbr_bytes, self.nbr_slices)

    cdef int _get_bit(self, unsigned long index):
        bytepos, bitpos = divmod(index, 8)
        return (self.bitarray[bytepos] >> bitpos) & 1

    def get_bit(self, unsigned long index):
        return self._get_bit(index)

    cdef void _set_bit(self, int index, int value):
        cdef int bytepos
        cdef int bitpos
        bytepos, bitpos = divmod(index, 8)
        if value:
            self.bitarray[bytepos] |= 1 << bitpos
        else:
            self.bitarray[bytepos] &= ~(1 << bitpos)

    def set_bit(self, unsigned long index, int value):
        self._set_bit(index, value)

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef double _get_nbr_nonzero(self):
        cdef int nonzero = 0
        cdef int count = 0
        for bytepos in range(self.nbr_bytes):
            val = self.bitarray[bytepos]
            count = 0
            while val != 0:
                val &= val-1
                count += 1
            nonzero += count
        return nonzero

    def get_fillrate(self):
        return self._get_nbr_nonzero() / self.nbr_bits

    def cardinality_estimation(self):
        """Estimate the cardinality of the filter.

        We can have an estimation of the cardinality using the fillrate:
        Swamidass and Baldi (2007)
        http://www.igb.uci.edu/~pfbaldi/publications/journals/2007/ci600526a.pdf
        """
        cardinality = float(self.nbr_bits) * log(1.0 - self.get_fillrate()) / self.nbr_slices
        return -cardinality

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef int _check_or_add(self, const char *value, int should_add=1):
        cdef int hits = 0
        cdef int val_len = len(value)
        cdef unsigned long a
        cdef unsigned long b
        cdef unsigned long x
        cdef unsigned long i
        cdef unsigned long byte
        cdef unsigned long mask
        cdef unsigned char c

        MurmurHash3_x64_128(<char*> value, val_len, 0x9747b28c, &a)
        MurmurHash3_x64_128(<char*> value, val_len, a, &b)

        for i in range(self.nbr_slices):
            x = (a + i * b) % self.nbr_bits
            byte = x >> 3
            c = self.bitarray[byte]
            mask = 1 << (x % 8)

            if c & mask:
                hits += 1
            else:
                if should_add == 1:
                    self.bitarray[byte] = c | mask

        if hits == self.nbr_slices:
            return 1

        if should_add:
            self._count += 1

        return 0

    @property
    def count(self):
        return self._count

    def add(self, const char *value):
        return self._check_or_add(value, True) == 1

    def contains(self, const char *value):
        return self._check_or_add(value, False) == 1

    def __contains__(self, value):
        return self.contains(value)

    def __dealloc__(self):
        PyMem_Free(self.bitarray)


cdef class DailyTemporalBase(BloomFilter):

    cdef unsigned char *current_day_bitarray

    def __cinit__(self, capacity, error_rate):
        self.capacity = capacity
        self.error_rate = error_rate
        self._count = 0
        self._initialize_parameters()
        self._allocate_bitarrays()

    def _allocate_bitarrays(self):
        self.current_day_bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))
        self.bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))
        if not (self.bitarray and self.current_day_bitarray):
            raise MemoryError("Unable to allocate memory for BloomFilter")
        else:
            self._initialize_bitarray()

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef int _check_or_add_all(self, const char *value, int should_add=1, int update_current=1):
        cdef int hits = 0
        cdef int val_len = len(value)
        cdef unsigned long a
        cdef unsigned long b
        cdef unsigned long x
        cdef unsigned long i
        cdef unsigned long byte
        cdef unsigned long mask
        cdef unsigned char c

        MurmurHash3_x64_128(<char*> value, val_len, 0x9747b28c, &a)
        MurmurHash3_x64_128(<char*> value, val_len, a, &b)

        for i in range(self.nbr_slices):
            x = (a + i * b) % self.nbr_bits
            byte = x >> 3
            c = self.bitarray[byte]
            mask = 1 << (x % 8)

            if c & mask:
                hits += 1
            else:
                if should_add == 1:
                    self.bitarray[byte] = c | mask
                    if update_current == 1:
                        self.current_day_bitarray[byte] = c | mask

        if hits == self.nbr_slices:
            return 1

        if should_add:
            self._count += 1

        return 0

    def add(self, const char *value):
        """Update the filter.

        :update_current: Update the current_bitarray and bitarray if True (realtime use).
        """
        return self._check_or_add_all(value, should_add=1, update_current=1) == 1

    def _save_snapshot(self,  char* filename, current=True):
        """Save bitarray into a simple binary file."""
        f = fopen(filename, 'w')
        # Write the header
        fwrite(&(self.capacity), sizeof(unsigned long long), 1, f)
        fwrite(&(self.error_rate), sizeof(double), 1, f)
        fwrite(&(self._count), sizeof(unsigned long long), 1, f)
        # Write the data
        if current:
            fwrite(self.current_day_bitarray, 1, self.nbr_bytes, f)
        else:
            fwrite(self.bitarray, 1, self.nbr_bytes, f)
        fclose(f)

    def _union_bf_from_file(self, char* filename, current=False):
        """Union the bitarray with an other one stored on file.

        Return True if the file was correctly unioned, False otherwise.
        """
        cdef unsigned long long new_capacity
        cdef unsigned long long new_count
        cdef double new_error_rate

        f = fopen(filename, "r")
        fread(&(new_capacity), sizeof(unsigned long long), 1, f)
        fread(&(new_error_rate), sizeof(double), 1, f)
        fread(&(new_count), sizeof(unsigned long long), 1, f)

        if (new_capacity != self.capacity) or (new_error_rate != self.error_rate):
            return False

        self._initialize_parameters()
        temp_bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))

        fread(temp_bitarray, 1, self.nbr_bytes, f)
        fclose(f)

        if current:
            ### TODO: Dealloc previous array
            self.current_day_bitarray = <unsigned char*> PyMem_Malloc(self.nbr_bytes * sizeof(unsigned char))
            self._initialize_current_day_bitarray()
            self._bitarray_or(self.current_day_bitarray, temp_bitarray)
        self._bitarray_or(self.bitarray, temp_bitarray)

        PyMem_Free(temp_bitarray)

        return True

    def union_current_day(self, DailyTemporalBase other):
        self._bitarray_or(self.bitarray, other.current_day_bitarray)

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef void _initialize_bitarray(self):
        for i in range(self.nbr_bytes):
            self.bitarray[i] = 0
            self.current_day_bitarray[i] = 0

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef void _initialize_current_day_bitarray(self):
        for i in range(self.nbr_bytes):
            self.current_day_bitarray[i] = 0

    def initialize_current_day_bitarray(self):
        self._initialize_current_day_bitarray()

    def __dealloc__(self):
        # The __dealloc__ of the superclass is always call
        # So bitarray will be dealloc there
        PyMem_Free(self.current_day_bitarray)


