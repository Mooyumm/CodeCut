import assert from 'node:assert/strict'
import {normalizeSegments, makeFCPXML} from './timeline.js'
const segments=[{start:0,end:2,text:'保留',decision:'keep'},{start:3,end:4,text:'删除',decision:'delete'},{start:5,end:7,text:'保留二',decision:'keep'}]
assert.deepEqual(normalizeSegments(segments,true).map(x=>x.text),['保留','保留二'])
const xml=makeFCPXML({name:'a&b.mp4',sourceUrl:'file:///a&b.mp4',duration:7,segments,removeBreaths:true})
assert.match(xml,/a&amp;b\.mp4/);assert.doesNotMatch(xml,/name="删除"/);assert.match(xml,/fcpxml/)
console.log('timeline checks passed')
