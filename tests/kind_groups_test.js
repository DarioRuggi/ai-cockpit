// kind_groups_test.js — js/chat/input.js _kindGroups() / _kindMatches(): the fields of the kind picker, their order, and the search.   node tests/kind_groups_test.js
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(__dirname + '/../cockpit_app/js/chat/input.js', 'utf8');
const m1 = src.match(/const _KIND_GROUP_ORDER = [^\n]*\n/), m2 = src.match(/function _kindGroups\(list\) \{[\s\S]*?\n\}\n/), m3 = src.match(/function _kindMatches\(k, q\) \{[\s\S]*?\n\}\n/);
if (!m1 || !m2 || !m3) { console.log('FAIL could not find the helpers'); process.exit(1); }
const ctx = {}; vm.createContext(ctx); vm.runInContext(m1[0].replace('const ', 'var ') + m2[0] + m3[0], ctx);
let fails = 0, n = 0; const eq = (name, got, want) => { n++; const g = JSON.stringify(got), w = JSON.stringify(want); if (g !== w) { fails++; console.log('FAIL ' + name + ': ' + g + ' want ' + w); } };
const kinds = [
  { id: 'lazarus', name: 'Lazarus', group: 'Software & games' }, { id: 'general', name: 'General', group: 'General' }, { id: 'podcast', name: 'Podcast', group: 'Media' },
  { id: 'mine', name: 'Mine', source: 'user' }, { id: 'zeta', name: 'Zeta', group: 'Zoology', source: 'user' }, { id: 'old', name: 'Old' }, { id: 'audio', name: 'Audio and Video', group: 'Media' }];
const g = ctx._kindGroups(kinds);
eq('known groups first in their fixed order, then others A-Z, then My kinds, then Other', g.map(x => x.name), ['General', 'Media', 'Software & games', 'Zoology', 'My kinds', 'Other']);
eq('kinds inside a group are sorted by name', g.find(x => x.name === 'Media').kinds.map(k => k.id), ['audio', 'podcast']);
eq('a user kind without a group goes to My kinds', g.find(x => x.name === 'My kinds').kinds.map(k => k.id), ['mine']);
eq('a shipped kind without a group goes to Other', g.find(x => x.name === 'Other').kinds.map(k => k.id), ['old']);
eq('general stays first in its group', ctx._kindGroups([{ id: 'b', name: 'B', group: 'General' }, { id: 'general', name: 'Z General', group: 'General' }])[0].kinds[0].id, 'general');
const k = { name: 'Subtitling', description: 'Subtitles for video', details: 'Keep timing exact', group: 'Media', examples: ['Burn in SRT files'] };
eq('search: name', ctx._kindMatches(k, 'subtit'), true); eq('search: details', ctx._kindMatches(k, 'TIMING'), true);
eq('search: an example', ctx._kindMatches(k, 'burn in'), true); eq('search: the group', ctx._kindMatches(k, 'media'), true);
eq('search: no match', ctx._kindMatches(k, 'pascal'), false); eq('search: empty matches everything', ctx._kindMatches(k, ''), true);
console.log('kind_groups_test: ' + n + ' checks, ' + fails + ' failure(s)'); process.exit(fails ? 1 : 0);
