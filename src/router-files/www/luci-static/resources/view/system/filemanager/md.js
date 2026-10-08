
function parseMarkdown(markdown){const lines=markdown.split('\n');const html=[];const listStack=[];function closeListsToIndent(indent){while(listStack.length>0&&listStack[listStack.length-1].indent>=indent){const last=listStack.pop();html.push(`</${last.type}>`);}}
function openList(type,indent,startNumber=null){listStack.push({type,indent});if(type==="ol"&&startNumber!=null&&startNumber!==1)
html.push(`<ol start="${startNumber}">`);else
html.push(`<${type}>`);}
lines.forEach(line=>{const indentSpaces=line.match(/^ */)[0].length;const indent=Math.floor(indentSpaces/2);const trimmed=line.trim();if(trimmed===""){closeListsToIndent(0);return;}
if(/^###\s+/.test(trimmed)){closeListsToIndent(0);html.push(`<h3>${escapeHtml(trimmed.replace(/^###\s+/, ''))}</h3>`);return;}
if(/^##\s+/.test(trimmed)){closeListsToIndent(0);html.push(`<h2>${escapeHtml(trimmed.replace(/^##\s+/, ''))}</h2>`);return;}
if(/^#\s+/.test(trimmed)){closeListsToIndent(0);html.push(`<h1>${escapeHtml(trimmed.replace(/^#\s+/, ''))}</h1>`);return;}
let mOrdered=trimmed.match(/^(\d+)\.\s+(.*)/);if(mOrdered){const num=parseInt(mOrdered[1],10);const content=mOrdered[2];const last=listStack[listStack.length-1];if(!last||last.indent<indent||last.type!=="ol"){closeListsToIndent(indent);openList("ol",indent,num);}
html.push(`<li>${parseInlineMarkdown(escapeHtml(content))}</li>`);return;}
let mUnordered=trimmed.match(/^[-*]\s+(.*)/);if(mUnordered){const content=mUnordered[1];const last=listStack[listStack.length-1];if(!last||last.indent<indent||last.type!=="ul"){closeListsToIndent(indent);openList("ul",indent);}
html.push(`<li>${parseInlineMarkdown(escapeHtml(content))}</li>`);return;}
closeListsToIndent(0);html.push(`<p>${parseInlineMarkdown(escapeHtml(trimmed))}</p>`);});closeListsToIndent(0);return html.join('\n');}
function parseInlineMarkdown(text){return text.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>').replace(/__(.+?)__/g,'<strong>$1</strong>');}
function escapeHtml(text){const map={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;',};return text.replace(/[&<>"']/g,function(m){return map[m];});}
return L.Class.extend({parseMarkdown:parseMarkdown,});