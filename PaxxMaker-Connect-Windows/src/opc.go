package main

// Reader for OrcaSlicer's preset cache files (<vendor>.opc), the form in which
// OrcaSlicer 2.5 ships its system profiles instead of JSON files. Format
// (OrcaSlicer src/libslic3r/PresetCacheFormat.cpp, CACHE_VERSION 2): a 20-byte
// header (magic "ZCRO", version, body size, CRC-32) and a cereal binary body —
// stamps, an option dictionary, the vendor map, then the process, filament and
// machine presets, each as its own diff plus inherits/includes. Values come out
// as the text a JSON profile carries. (Same as OrcaPresetCache.swift.)

import (
	"encoding/binary"
	"errors"
	"math"
	"os"
	"strconv"
	"strings"
)

type opcEntry struct {
	Kind          string // "process" / "filament" / "machine"
	Name          string
	Values        JSONObject
	Inherits      string
	Includes      []string
	Instantiation string
	SettingID     string
	FilamentID    string
}

type opcReader struct {
	d []byte
	p int
}

var errOPC = errors.New("preset cache: bad data")

func (r *opcReader) take(n int) ([]byte, error) {
	if n < 0 || r.p+n > len(r.d) {
		return nil, errOPC
	}
	b := r.d[r.p : r.p+n]
	r.p += n
	return b, nil
}
func (r *opcReader) u8() (uint8, error) {
	b, err := r.take(1)
	if err != nil {
		return 0, err
	}
	return b[0], nil
}
func (r *opcReader) u16() (uint16, error) {
	b, err := r.take(2)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint16(b), nil
}
func (r *opcReader) u32() (uint32, error) {
	b, err := r.take(4)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(b), nil
}
func (r *opcReader) u64() (uint64, error) {
	b, err := r.take(8)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(b), nil
}
func (r *opcReader) i32() (int32, error) {
	v, err := r.u32()
	return int32(v), err
}
func (r *opcReader) f64() (float64, error) {
	v, err := r.u64()
	return math.Float64frombits(v), err
}
func (r *opcReader) str() (string, error) {
	n, err := r.u64()
	if err != nil || n > 50_000_000 {
		return "", errOPC
	}
	b, err := r.take(int(n))
	return string(b), err
}
func (r *opcReader) strs() ([]string, error) {
	n, err := r.u64()
	if err != nil || n > 1_000_000 {
		return nil, errOPC
	}
	out := make([]string, 0, n)
	for i := uint64(0); i < n; i++ {
		s, err := r.str()
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

// Like Orca writes numbers: no trailing ".0", up to 15 significant digits.
func opcNum(v float64, nilIfNaN bool) string {
	if math.IsNaN(v) {
		if nilIfNaN {
			return "nil"
		}
		return "0"
	}
	if v == math.Trunc(v) && math.Abs(v) < 1e15 {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'g', 15, 64)
}
func opcPct(v float64) string {
	if math.IsNaN(v) {
		return "nil"
	}
	return opcNum(v, false) + "%"
}
func opcInt(v int32) string {
	if v == math.MaxInt32 {
		return "nil"
	}
	return strconv.Itoa(int(v))
}

func (r *opcReader) point() (string, error) {
	x, err := r.f64()
	if err != nil {
		return "", err
	}
	y, err := r.f64()
	if err != nil {
		return "", err
	}
	return opcNum(x, false) + "x" + opcNum(y, false), nil
}

// One option as JSON-profile text: a string, or a list of strings for a vector.
func (r *opcReader) value(typ uint16, enums []string) (any, error) {
	const vec = 0x4000
	isVec := typ&vec != 0
	base := typ &^ vec
	list := func(each func() (string, error)) (any, error) {
		n, err := r.u64()
		if err != nil || n > 1_000_000 {
			return nil, errOPC
		}
		out := make([]any, 0, n)
		for i := uint64(0); i < n; i++ {
			s, err := each()
			if err != nil {
				return nil, err
			}
			out = append(out, s)
		}
		return out, nil
	}
	switch base {
	case 1: // float(s)
		each := func() (string, error) { v, err := r.f64(); return opcNum(v, isVec), err }
		if isVec {
			return list(each)
		}
		return each()
	case 2: // int(s)
		each := func() (string, error) { v, err := r.i32(); return opcInt(v), err }
		if isVec {
			return list(each)
		}
		return each()
	case 3: // string(s)
		if isVec {
			return list(r.str)
		}
		return r.str()
	case 4: // percent(s)
		each := func() (string, error) { v, err := r.f64(); return opcPct(v), err }
		if isVec {
			return list(each)
		}
		return each()
	case 5: // float-or-percent(s)
		each := func() (string, error) {
			v, err := r.f64()
			if err != nil {
				return "", err
			}
			p, err := r.u8()
			if p != 0 {
				return opcPct(v), err
			}
			return opcNum(v, isVec), err
		}
		if isVec {
			return list(each)
		}
		return each()
	case 6: // point(s)
		if isVec {
			return list(r.point)
		}
		return r.point()
	case 7: // point3
		var s []string
		for i := 0; i < 3; i++ {
			v, err := r.f64()
			if err != nil {
				return nil, err
			}
			s = append(s, opcNum(v, false))
		}
		return strings.Join(s, "x"), nil
	case 8: // bool(s)
		each := func() (string, error) {
			b, err := r.u8()
			switch {
			case b == 255 && isVec:
				return "nil", err
			case b != 0:
				return "1", err
			}
			return "0", err
		}
		if isVec {
			return list(each)
		}
		return each()
	case 9: // enum(s), by name
		n, err := r.u32()
		if err != nil {
			return nil, err
		}
		names := make([]any, 0, n)
		for i := uint32(0); i < n; i++ {
			idx, err := r.u16()
			if err != nil || int(idx) >= len(enums) {
				return nil, errOPC
			}
			if idx == 0 {
				raw, err := r.i32()
				if err != nil {
					return nil, err
				}
				names = append(names, opcInt(raw))
			} else {
				names = append(names, enums[idx])
			}
		}
		if isVec {
			return names, nil
		}
		if len(names) == 0 {
			return "", nil
		}
		return names[0], nil
	case 10: // points groups
		return list(func() (string, error) {
			m, err := r.u64()
			if err != nil || m > 1_000_000 {
				return "", errOPC
			}
			var parts []string
			for j := uint64(0); j < m; j++ {
				p, err := r.point()
				if err != nil {
					return "", err
				}
				parts = append(parts, p)
			}
			return strings.Join(parts, ","), nil
		})
	case 11: // ints groups
		return list(func() (string, error) {
			m, err := r.u64()
			if err != nil || m > 1_000_000 {
				return "", errOPC
			}
			var parts []string
			for j := uint64(0); j < m; j++ {
				v, err := r.i32()
				if err != nil {
					return "", err
				}
				parts = append(parts, opcInt(v))
			}
			return strings.Join(parts, ","), nil
		})
	}
	return nil, errOPC
}

// The vendor map is skipped — only its length matters.
func (r *opcReader) skipVendors() error {
	n, err := r.u64()
	if err != nil || n > 10_000 {
		return errOPC
	}
	for i := uint64(0); i < n; i++ {
		for k := 0; k < 6; k++ { // map key, name, id, version, update url, changelog url
			if _, err := r.str(); err != nil {
				return err
			}
		}
		models, err := r.u64()
		if err != nil || models > 100_000 {
			return errOPC
		}
		for m := uint64(0); m < models; m++ {
			for k := 0; k < 3; k++ { // id, name, model_id
				if _, err := r.str(); err != nil {
					return err
				}
			}
			if _, err := r.u8(); err != nil { // technology
				return err
			}
			if _, err := r.str(); err != nil { // family
				return err
			}
			for k := 0; k < 3; k++ { // variants, default_materials, not_support_bed_types
				if _, err := r.strs(); err != nil {
					return err
				}
			}
			for k := 0; k < 9; k++ { // bed model … hotend model
				if _, err := r.str(); err != nil {
					return err
				}
			}
		}
		for k := 0; k < 2; k++ { // default_filaments, default_sla_materials
			if _, err := r.strs(); err != nil {
				return err
			}
		}
	}
	return nil
}

// readOPC returns every preset in one cache file; nil when it is not a cache
// this reader knows.
func readOPC(path string) []opcEntry {
	data, err := os.ReadFile(path)
	if err != nil || len(data) <= 20 {
		return nil
	}
	r := &opcReader{d: data}
	parse := func() ([]opcEntry, error) {
		if m, _ := r.u32(); m != 0x4F52435A {
			return nil, errOPC
		}
		r.u32() // file format version
		size, _ := r.u64()
		r.u32() // CRC
		if size != uint64(len(data)-20) {
			return nil, errOPC
		}
		if v, _ := r.u32(); v != 2 {
			return nil, errOPC
		}
		if _, err := r.str(); err != nil { // vendor name
			return nil, err
		}
		if _, err := r.str(); err != nil { // vendor version
			return nil, err
		}
		keys, err := r.strs()
		if err != nil {
			return nil, err
		}
		tn, err := r.u64()
		if err != nil || tn != uint64(len(keys)) {
			return nil, errOPC
		}
		types := make([]uint16, tn)
		for i := range types {
			if types[i], err = r.u16(); err != nil {
				return nil, err
			}
		}
		enums, err := r.strs()
		if err != nil {
			return nil, err
		}
		if err := r.skipVendors(); err != nil {
			return nil, err
		}
		var out []opcEntry
		for _, kind := range []string{"process", "filament", "machine"} {
			n, err := r.u32()
			if err != nil {
				return nil, err
			}
			for i := uint32(0); i < n; i++ {
				var e opcEntry
				e.Kind = kind
				if e.Name, err = r.str(); err != nil {
					return nil, err
				}
				if _, err = r.str(); err != nil { // sub_path
					return nil, err
				}
				cnt, err := r.u32()
				if err != nil {
					return nil, err
				}
				e.Values = JSONObject{}
				for c := uint32(0); c < cnt; c++ {
					idx, err := r.u16()
					if err != nil || int(idx) >= len(keys) {
						return nil, errOPC
					}
					v, err := r.value(types[idx], enums)
					if err != nil {
						return nil, err
					}
					e.Values[keys[idx]] = v
				}
				if e.Inherits, err = r.str(); err != nil {
					return nil, err
				}
				if e.Includes, err = r.strs(); err != nil {
					return nil, err
				}
				if _, err = r.str(); err != nil { // description
					return nil, err
				}
				if e.Instantiation, err = r.str(); err != nil {
					return nil, err
				}
				if e.SettingID, err = r.str(); err != nil {
					return nil, err
				}
				if e.FilamentID, err = r.str(); err != nil {
					return nil, err
				}
				if _, err = r.strs(); err != nil { // renamed_from
					return nil, err
				}
				out = append(out, e)
			}
		}
		return out, nil
	}
	out, err := parse()
	if err != nil {
		return nil
	}
	return out
}
