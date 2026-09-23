package main

// Writes a plain 3MF (core spec) from STL meshes with one transform per
// object — the way the phone's placement reaches Orca exactly, since the CLI
// has no flag for a free position. The head per object goes into
// Metadata/model_settings.config and painted faces into Orca's paint_color
// triangle attribute, which is how Orca's own projects carry colour
// painting. (Port of ThreeMF.swift.)

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

type Vec3 struct{ X, Y, Z float32 }

type ThreeMFObject struct {
	Name      string
	STL       []byte
	Transform []float64 // column-major 4×4, 16 values
	Extruder  int
	// Orca's paint_color string per triangle index (same order as the STL):
	// the phone serialises its subdivision tree exactly like
	// TriangleSelector::serialize, so Orca reads it as its own painting.
	Paint map[int]string
	// The object's own process settings (Orca keys and value spellings),
	// written as metadata like Orca's per-object overrides.
	Settings map[string]string
}

func xmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "\"", "&quot;", "<", "&lt;", ">", "&gt;")
	return r.Replace(s)
}

type tri [3]int

// STL → deduplicated vertices + index triples.
func readSTL(data []byte) ([]Vec3, []tri) {
	var verts []Vec3
	var tris []tri
	index := map[Vec3]int{}
	vid := func(p Vec3) int {
		k := Vec3{float32(math.Round(float64(p.X)*1e5) / 1e5), float32(math.Round(float64(p.Y)*1e5) / 1e5), float32(math.Round(float64(p.Z)*1e5) / 1e5)}
		if i, ok := index[k]; ok {
			return i
		}
		i := len(verts)
		index[k] = i
		verts = append(verts, k)
		return i
	}
	if len(data) >= 84 {
		n := int(binary.LittleEndian.Uint32(data[80:84]))
		if len(data) == 84+n*50 {
			off := 84
			for i := 0; i < n; i++ {
				off += 12
				var t tri
				for k := 0; k < 3; k++ {
					x := math.Float32frombits(binary.LittleEndian.Uint32(data[off:]))
					y := math.Float32frombits(binary.LittleEndian.Uint32(data[off+4:]))
					z := math.Float32frombits(binary.LittleEndian.Uint32(data[off+8:]))
					t[k] = vid(Vec3{x, y, z})
					off += 12
				}
				off += 2
				tris = append(tris, t)
			}
			return verts, tris
		}
	}
	// ASCII STL
	var cur []int
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(line)
		if !strings.HasPrefix(t, "vertex") {
			continue
		}
		p := strings.Fields(t)
		if len(p) < 4 {
			continue
		}
		x, e1 := strconv.ParseFloat(p[1], 32)
		y, e2 := strconv.ParseFloat(p[2], 32)
		z, e3 := strconv.ParseFloat(p[3], 32)
		if e1 != nil || e2 != nil || e3 != nil {
			continue
		}
		cur = append(cur, vid(Vec3{float32(x), float32(y), float32(z)}))
		if len(cur) == 3 {
			tris = append(tris, tri{cur[0], cur[1], cur[2]})
			cur = nil
		}
	}
	return verts, tris
}

// 3MF transform attribute from a column-major 4×4 (16 doubles).
func matrixAttr(m []float64) string {
	if len(m) != 16 {
		return "1 0 0 0 1 0 0 0 1 0 0 0"
	}
	v := []float64{m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14]}
	parts := make([]string, len(v))
	for i, x := range v {
		parts[i] = fmt.Sprintf("%.6f", x)
	}
	return strings.Join(parts, " ")
}

func isHex(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func isKeyChar(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

func buildThreeMF(objects []ThreeMFObject) ([]byte, error) {
	var xml strings.Builder
	xml.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources>")
	var items strings.Builder
	var settings strings.Builder
	settings.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n")
	for i, o := range objects {
		id := i + 1
		verts, tris := readSTL(o.STL)
		name := strings.NewReplacer("\"", "", "&", "+", "<", "").Replace(o.Name)
		fmt.Fprintf(&xml, "<object id=\"%d\" name=\"%s\" type=\"model\"><mesh><vertices>", id, name)
		for _, v := range verts {
			fmt.Fprintf(&xml, "<vertex x=\"%.5f\" y=\"%.5f\" z=\"%.5f\"/>", v.X, v.Y, v.Z)
		}
		xml.WriteString("</vertices><triangles>")
		for ti, t := range tris {
			if code, ok := o.Paint[ti]; ok && isHex(code) {
				fmt.Fprintf(&xml, "<triangle v1=\"%d\" v2=\"%d\" v3=\"%d\" paint_color=\"%s\"/>", t[0], t[1], t[2], code)
			} else {
				fmt.Fprintf(&xml, "<triangle v1=\"%d\" v2=\"%d\" v3=\"%d\"/>", t[0], t[1], t[2])
			}
		}
		xml.WriteString("</triangles></mesh></object>")
		fmt.Fprintf(&items, "<item objectid=\"%d\" transform=\"%s\"/>", id, matrixAttr(o.Transform))
		ext := o.Extruder
		if ext < 1 {
			ext = 1
		}
		fmt.Fprintf(&settings, "  <object id=\"%d\">\n    <metadata key=\"name\" value=\"%s\"/>\n    <metadata key=\"extruder\" value=\"%d\"/>\n", id, name, ext)
		keys := make([]string, 0, len(o.Settings))
		for k := range o.Settings {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			valid := k != ""
			for _, c := range k {
				if !isKeyChar(c) {
					valid = false
					break
				}
			}
			if valid {
				fmt.Fprintf(&settings, "    <metadata key=\"%s\" value=\"%s\"/>\n", k, xmlEscape(o.Settings[k]))
			}
		}
		settings.WriteString("  </object>\n")
	}
	settings.WriteString("</config>\n")
	fmt.Fprintf(&xml, "</resources><build>%s</build></model>", items.String())
	types := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/></Types>"
	rels := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	entries := []struct{ name, body string }{
		{"[Content_Types].xml", types}, {"_rels/.rels", rels},
		{"3D/3dmodel.model", xml.String()}, {"Metadata/model_settings.config", settings.String()},
	}
	for _, e := range entries {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: e.name, Method: zip.Deflate})
		if err != nil {
			return nil, err
		}
		if _, err := w.Write([]byte(e.body)); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
