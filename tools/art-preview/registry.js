import {items as originalItems} from './catalog.js';
import {immuneItems} from './immune-catalog.js';
import {cancerItems} from './cancer-catalog.js';
import {commonItems} from './common-catalog.js';
import {immuneEffects} from './immune-skills.js';
import {cancerEffects} from './cancer-skills.js';
import {commonEffects} from './common-skills.js';
import {hunt,neutralize,excalibur} from './combat.js';
import {chain,rupture} from './feeding.js';
import {removedIds,revise,extraItems} from './revised-catalog.js';
import {revisedEffects} from './revised-effects.js';

export const items=[...originalItems,...immuneItems,...cancerItems,...commonItems].filter(item=>!removedIds.has(item.id)).map(revise).concat(extraItems);
export const effects={hunt,neutralize,excalibur,chain,rupture,...immuneEffects,...cancerEffects,...commonEffects,...revisedEffects};
export function matches(item,category,query) {
  const group=category==='all'||(category==='original'&&(originalItems.some(original=>original.id===item.id)||item.id==='necrosis'))
    ||(category==='immune'&&(item.id.startsWith('immune_')||['chain','hunt','neutralize','excalibur'].includes(item.id)))
    ||(category==='cancer'&&(item.id.startsWith('cancer_')||['rupture','mark_visual'].includes(item.id)))
    ||(category==='shared'&&['necrosis','marrow','mucus','mark_visual'].includes(item.id));
  return group&&`${item.name} ${item.group} ${item.description}`.toLowerCase().includes(query.trim().toLowerCase());
}
