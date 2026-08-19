export function normalizeSegments(segments, removeBreaths = true, breathThreshold = .45) {
  const kept = segments.filter(segment => segment.decision !== 'delete').sort((a, b) => a.start - b.start)
  const ranges = []
  for (let i = 0; i < kept.length; i++) {
    const segment = kept[i]
    let start = segment.start
    let end = segment.end
    if (!removeBreaths && i < kept.length - 1) end = kept[i + 1].start
    if (removeBreaths && i < kept.length - 1 && kept[i + 1].start - end <= breathThreshold) end = kept[i + 1].start
    if (end > start) ranges.push({...segment, start, end})
  }
  return ranges
}

export function makeFCPXML({name, sourceUrl, duration, segments, removeBreaths}) {
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]))
  const frames = seconds => `${Math.max(0, Math.round(seconds * 25))}/25s`
  const clips = normalizeSegments(segments, removeBreaths).map((segment, index) =>
    `            <asset-clip name="${esc(segment.text || `片段 ${index + 1}`)}" ref="r2" offset="${frames(index ? normalizeSegments(segments, removeBreaths).slice(0,index).reduce((n,s)=>n+s.end-s.start,0) : 0)}" start="${frames(segment.start)}" duration="${frames(segment.end-segment.start)}"><marker start="0s" value="${esc(segment.text)}"/></asset-clip>`
  ).join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>
<fcpxml version="1.10"><resources><format id="r1" name="FFVideoFormat1080p25" frameDuration="1/25s" width="1920" height="1080"/><asset id="r2" name="${esc(name)}" src="${esc(sourceUrl)}" start="0s" duration="${frames(duration)}" hasVideo="1" hasAudio="1" format="r1"/></resources><library><event name="CutFlow"><project name="${esc(name)} - 快编"><sequence format="r1" tcStart="0s" tcFormat="NDF"><spine>
${clips}
          </spine></sequence></project></event></library></fcpxml>`
}
