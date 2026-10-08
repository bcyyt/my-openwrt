
const _NON_PRINTABLE_CHAR="\u00B7";function _byteToChar(b){return(b>=32&&b<=126)?String.fromCharCode(b):_NON_PRINTABLE_CHAR;}
function injectHexEditorCSS(){if(document.getElementById('hexeditor-styles'))return;const style=document.createElement('style');style.id='hexeditor-styles';style.type='text/css';style.innerText=hexeditCssContent;document.head.appendChild(style);}
var hexeditCssContent=`
/* Hex Editor CSS Styles */

#file-manager-container .hexview:focus,
#file-manager-container .textview:focus {
 outline: none;
 box-shadow: none;
 border-right: 2px solid var(--clr-border); 
}

:root {
 --span-spacing: 0.25ch;
 --clr-background: #f5f5f5;
 --clr-selected: #c9daf8;
 --clr-selected-editing: #6d9eeb;
 --clr-non-printable: #999999;
 --clr-border: #000000;
 --clr-offset: #666666;
 --clr-header: #333333;
 --clr-highlight: yellow; /* Unified highlight color for matches */
 --clr-cursor-active: blue; /* Active cursor base color */
 --clr-cursor-passive: lightblue; /* Passive cursor color */
 --animation-duration: 1s; /* Duration for blinking animation */
}

/* Apply box-sizing to all elements */
#file-manager-container .hexedit *,
#file-manager-container .hexedit *::before,
#file-manager-container .hexedit *::after {
 box-sizing: border-box;
}

/* Main hex editor container */
#file-manager-container .hexedit {
 display: flex;
 flex-direction: column;
 flex: 1; /* Allow hexedit to expand */
 font-family: monospace;
 font-size: 14px;
 line-height: 1.2em;
 border: 1px solid var(--clr-border);
 width: 100%;
}

#file-manager-container .hexedit:focus {
 outline: none;
}

/* Headers container */
#file-manager-container .hexedit-headers {
 display: flex;
 border-bottom: 2px solid var(--clr-border);
 font-family: monospace;
 background: #ccc;
}

/* Header styles */
#file-manager-container .offsets-header,
#file-manager-container .hexview-header,
#file-manager-container .textview-header {
 display: flex;
 align-items: center;
 padding: 5px;
 box-sizing: border-box;
 font-weight: bold;
 color: var(--clr-header);
 border-right: 2px solid var(--clr-border);
}

#file-manager-container .offsets-header {
 width: 100px; /* Ensure alignment with .offsets */
 text-align: left;
}

#file-manager-container .hexview-header {
 width: calc(16 * 2ch + 20 * var(--span-spacing)); /* Increased width to match content */
 display: flex;
}

#file-manager-container .hexview-header span {
 width: 2ch;
 margin-right: var(--span-spacing);
 text-align: center;
}

#file-manager-container .hexview-header span:last-child {
 margin-right: 0;
}

#file-manager-container .textview-header {
 flex: 1;
 margin-left: 10px;
 text-align: left;
}

/* Content container */
#file-manager-container .hexedit-content {
 display: flex;
 height: 100%;
 flex: 1 1 auto;
 overflow: auto;
 position: relative;
 border-top: 2px solid var(--clr-border);
}

/* Columns */
#file-manager-container .offsets,
#file-manager-container .hexview,
#file-manager-container .textview {
 flex-shrink: 0;
 display: block;
 padding: 5px;
 position: relative;
 border-right: 2px solid var(--clr-border);
}

#file-manager-container .offsets {
 width: 100px; /* Increased width to match content */
 display: flex;
 flex-direction: column;
 text-align: left;
}

#file-manager-container .offsets span {
 display: block;
 height: 1.2em;
}

#file-manager-container .hexview {
 width: calc(16 * 2ch + 20 * var(--span-spacing)); /* Increased width to match content */
 text-align: center;
}

#file-manager-container .textview {
 flex: 1;
 margin-left: 10px;
 text-align: left;
 border-right: none;
}

/* Line containers */
#file-manager-container .hex-line,
#file-manager-container .text-line {
 display: flex;
 height: 1.2em;
}

/* Byte spans */
#file-manager-container .hex-line span,
#file-manager-container .text-line span {
 width: 2ch;
 margin-right: var(--span-spacing);
 text-align: center;
 display: inline-block;
 cursor: default;
}

#file-manager-container .hex-line span:last-child,
#file-manager-container .hexview-header span:last-child,
#file-manager-container .text-line span:last-child {
 margin-right: 0;
}

/* Selections */
#file-manager-container .selected {
 background-color: var(--clr-selected);
}

#file-manager-container .selected-editing {
 background-color: var(--clr-selected-editing);
}

#file-manager-container .non-printable {
 color: var(--clr-non-printable);
}

/* Remove individual scrollbars */
#file-manager-container .offsets::-webkit-scrollbar,
#file-manager-container .hexview::-webkit-scrollbar,
#file-manager-container .textview::-webkit-scrollbar {
 display: none;
}

#file-manager-container .offsets,
#file-manager-container .hexview,
#file-manager-container .textview {
 scrollbar-width: none; /* For Firefox */
}

/* Adjust overall layout */
#file-manager-container .hexedit .offsets,
#file-manager-container .hexedit .hexview,
#file-manager-container .hexedit .textview {
 border-right: 2px solid var(--clr-border);
}

#file-manager-container .hexedit .textview {
 border-right: none;
}

/* Responsive adjustments */
@media (max-width: 768px) {
 #file-manager-container .hexedit {
 font-size: 12px;
 }

 #file-manager-container .offsets {
 width: 120px; /* Adjust for smaller screens */
 }

 #file-manager-container .hexview {
 width: calc(16 * 2ch + 20 * var(--span-spacing));
 }
}

/* Search container styles */
#file-manager-container .hexedit-search-container {
 padding: 10px;
 border-bottom: 1px solid #ccc; /* Border to separate from headers */
 display: flex;
 flex-direction: column; /* Stack search groups vertically */
 gap: 10px;
 width: 100%;
 box-sizing: border-box;
}

/* Search group styles */
#file-manager-container .hexedit-search-group {
 display: flex;
 align-items: center;
 gap: 5px;
 width: 100%;
}

/* Search input fields */
#file-manager-container .hexedit-search-input {
 flex: 1;
 padding: 8px;
 border: 1px solid #ddd;
 border-radius: 4px;
 font-size: 14px;
}

/* Search status fields */
#file-manager-container .hexedit-search-status {
 width: 50px;
 text-align: center;
 font-size: 14px;
}

/* Find Previous and Next buttons */
#file-manager-container .hexedit-search-button {
 padding: 8px 12px;
 cursor: pointer;
 background-color: #007bff;
 color: white;
 border: none;
 border-radius: 4px;
 font-size: 14px;
 transition: background-color 0.3s ease;
}

#file-manager-container .hexedit-search-button:hover {
 background-color: #0056b3;
}

/* Highlight search results */
#file-manager-container .search-highlight {
 background-color: var(--clr-highlight);
}

/* Define keyframes for blinking blue */
@keyframes blink-blue {
 0% { background-color: var(--clr-cursor-active); }
 50% { background-color: white; }
 100% { background-color: var(--clr-cursor-active); }
}

/* Classes for active view cursor blinking */
#file-manager-container .active-view-cursor {
 animation: blink-blue var(--animation-duration) infinite;
 background-color: var(--clr-cursor-active); /* Initial color */
}

/* Classes for passive view cursor highlighting */
#file-manager-container .passive-view-cursor {
 background-color: var(--clr-cursor-passive);
 color: #000;
}

/* Highlighted class to maintain yellow background for matches */
#file-manager-container .highlighted {
 background-color: var(--clr-highlight);
}
`;injectHexEditorCSS();class HexEditor{constructor(hexeditDomObject){this.hexedit=_fillHexeditDom(hexeditDomObject);this.offsets=this.hexedit.querySelector('.offsets');this.hexview=this.hexedit.querySelector('.hexview');this.textview=this.hexedit.querySelector('.textview');this.hexeditContent=this.hexedit.querySelector('.hexedit-content');this.hexeditHeaders=this.hexedit.querySelector('.hexedit-headers');this.bytesPerRow=16;this.startIndex=0;this.data=new Uint8Array(0);this.selectedIndex=null;this.editHex=true;this.currentEdit="";this.readonly=false;this.ctrlPressed=false;this.matches=[];this.currentMatchIndex=-1;this.currentSearchType=null;this.activeView=null;this.previousSelectedIndex=null;this.lastSearchPatterns={ascii:'',hex:'',regex:''};this._registerEventHandlers();this.resizeObserver=new ResizeObserver(()=>{this.calculateVisibleRows();});this.resizeObserver.observe(this.hexeditContent);this.addSearchUI();}
addSearchUI(){const searchContainer=document.createElement('div');searchContainer.classList.add('hexedit-search-container');const createSearchGroup=(type,placeholder)=>{const container=document.createElement('div');container.classList.add('hexedit-search-group');const input=document.createElement('input');input.type='text';input.placeholder=placeholder;input.classList.add('hexedit-search-input');input.id=`hexedit-search-${type}`;const status=document.createElement('span');status.classList.add('hexedit-search-status');status.id=`hexedit-search-status-${type}`;status.textContent='0/0';const prevButton=document.createElement('button');prevButton.innerHTML='&#8593;';prevButton.classList.add('hexedit-search-button');prevButton.title=`Previous ${type.toUpperCase()} Match`;const nextButton=document.createElement('button');nextButton.innerHTML='&#8595;';nextButton.classList.add('hexedit-search-button');nextButton.title=`Next ${type.toUpperCase()} Match`;container.appendChild(input);container.appendChild(status);container.appendChild(prevButton);container.appendChild(nextButton);prevButton.addEventListener('click',()=>this.handleFindPrevious(type));nextButton.addEventListener('click',()=>this.handleFindNext(type));input.addEventListener('keydown',(e)=>{if(e.key==='Enter')this.handleFindNext(type);});return container;};const asciiGroup=createSearchGroup('ascii',_('Search ASCII'));const hexGroup=createSearchGroup('hex',_('Search HEX (e.g., 4F6B)'));const regexGroup=createSearchGroup('regex',_('Search RegExp (e.g., \\d{3})'));searchContainer.appendChild(asciiGroup);searchContainer.appendChild(hexGroup);searchContainer.appendChild(regexGroup);if(this.hexeditHeaders){this.hexedit.insertBefore(searchContainer,this.hexeditHeaders);}else{this.hexeditContent.insertBefore(searchContainer,this.hexeditContent.firstChild);}}
handleFindNext(searchType){const inputElement=document.getElementById(`hexedit-search-${searchType}`);const currentPattern=inputElement.value.trim();if(this.lastSearchPatterns[searchType]!==currentPattern){this.lastSearchPatterns[searchType]=currentPattern;this.currentSearchType=searchType;this.activeView=(searchType==='hex')?'hex':'text';this.performSearch(searchType);}else{if(this.currentSearchType===searchType&&this.matches.length>0){this.activeView=(this.currentSearchType==='hex')?'hex':'text';const cursorPosition=this.selectedIndex!==null?this.selectedIndex:0;const nextMatchIndex=this.findNextMatch(cursorPosition);if(nextMatchIndex!==-1){this.navigateToMatch(nextMatchIndex);}else{this.navigateToMatch(0);}}}}
handleFindPrevious(searchType){const inputElement=document.getElementById(`hexedit-search-${searchType}`);const currentPattern=inputElement.value.trim();if(this.lastSearchPatterns[searchType]!==currentPattern){this.lastSearchPatterns[searchType]=currentPattern;this.currentSearchType=searchType;this.activeView=(searchType==='hex')?'hex':'text';this.performSearch(searchType);}else{if(this.currentSearchType===searchType&&this.matches.length>0){this.activeView=(this.currentSearchType==='hex')?'hex':'text';const cursorPosition=this.selectedIndex!==null?this.selectedIndex:this.data.length;const prevMatchIndex=this.findPreviousMatch(cursorPosition);if(prevMatchIndex!==-1){this.navigateToMatch(prevMatchIndex);}else{this.navigateToMatch(this.matches.length-1);}}}}
findNextMatch(cursorPosition){for(let i=0;i<this.matches.length;i++){if(this.matches[i].index>cursorPosition){return i;}}
return-1;}
findPreviousMatch(cursorPosition){for(let i=this.matches.length-1;i>=0;i--){if(this.matches[i].index<cursorPosition){return i;}}
return-1;}
performSearch(searchType){let pattern='';switch(searchType){case'ascii':pattern=document.getElementById('hexedit-search-ascii').value.trim();break;case'hex':pattern=document.getElementById('hexedit-search-hex').value.trim();break;case'regex':pattern=document.getElementById('hexedit-search-regex').value.trim();break;default:pattern='';break;}
this.clearSearchHighlights();this.matches=[];this.currentMatchIndex=-1;if(!pattern){this.updateSearchStatus(searchType,0,0);return;}
try{if(searchType==='ascii'){this.searchASCII(pattern);}else if(searchType==='hex'){this.searchHEX(pattern);}else if(searchType==='regex'){this.searchRegex(pattern);}}catch(error){this.updateSearchStatus(searchType,0,0);return;}
if(this.matches.length>0){this.highlightAllMatches(searchType);this.currentMatchIndex=0;this.navigateToMatch(this.currentMatchIndex);this.updateSearchStatus(searchType,this.currentMatchIndex+1,this.matches.length);}else{this.updateSearchStatus(searchType,0,0);}}
highlightAllMatches(searchType){this.searchTypeForHighlight=searchType;if(searchType==='ascii'||searchType==='regex'){this.activeView='text';}else if(searchType==='hex'){this.activeView='hex';}
this.focusActiveView();this.renderDom();}
navigateToMatch(matchIndex){if(this.matches.length===0){this.updateSearchStatus(this.currentSearchType,0,0);return;}
if(matchIndex<0||matchIndex>=this.matches.length){return;}
this.currentMatchIndex=matchIndex;const match=this.matches[matchIndex];this.activeView=(this.currentSearchType==='hex')?'hex':'text';this.setSelectedIndex(match.index);this.updateSearchStatus(this.currentSearchType,this.currentMatchIndex+1,this.matches.length);}
searchASCII(pattern){const dataStr=new TextDecoder('iso-8859-1').decode(this.data);const regex=new RegExp(pattern,'g');let match;while((match=regex.exec(dataStr))!==null){this.matches.push({index:match.index,length:pattern.length});if(match.index===regex.lastIndex){regex.lastIndex++;}}}
searchHEX(pattern){const cleanedPattern=pattern.replace(/\s+/g,'');if(!/^[0-9a-fA-F]+$/.test(cleanedPattern)){throw new Error('Invalid HEX pattern.');}
if(cleanedPattern.length%2!==0){throw new Error('HEX pattern length must be even.');}
const bytePattern=new Uint8Array(cleanedPattern.match(/.{1,2}/g).map(byte=>parseInt(byte,16)));for(let i=0;i<=this.data.length-bytePattern.length;i++){let found=true;for(let j=0;j<bytePattern.length;j++){if(this.data[i+j]!==bytePattern[j]){found=false;break;}}
if(found){this.matches.push({index:i,length:bytePattern.length});}}}
searchRegex(regexPattern){const regex=new RegExp(regexPattern,'g');const dataStr=new TextDecoder('iso-8859-1').decode(this.data);let match;while((match=regex.exec(dataStr))!==null){const byteIndex=match.index;const length=match[0].length;this.matches.push({index:byteIndex,length:length});if(match.index===regex.lastIndex){regex.lastIndex++;}}}
scrollToMatch(index){const lineNumber=Math.floor(index/this.bytesPerRow);const lineHeight=16;const newScrollTop=Math.max(0,(lineNumber*lineHeight)-((this.visibleRows/2)*lineHeight));this.hexeditContent.scrollTop=newScrollTop;}
clearSearchHighlights(){this.hexview.querySelectorAll('.search-highlight').forEach(span=>{span.classList.remove('search-highlight');});this.textview.querySelectorAll('.search-highlight').forEach(span=>{span.classList.remove('search-highlight');});this.activeView=null;['ascii','hex','regex'].forEach(type=>{this.updateSearchStatus(type,0,0);});}
calculateVisibleRows(){const lineHeight=16;const containerHeight=this.hexeditContent.clientHeight;this.visibleRows=Math.floor(containerHeight/lineHeight);this.visibleByteCount=this.bytesPerRow*this.visibleRows;this.renderDom();}
setData(data){this.data=data;this.totalRows=Math.ceil(this.data.length/this.bytesPerRow);this.calculateVisibleRows();}
getData(){return this.data;}
handleScroll(event){const scrollTop=this.hexeditContent.scrollTop;const lineHeight=16;const firstVisibleLine=Math.floor(scrollTop/lineHeight);const newStartIndex=firstVisibleLine*this.bytesPerRow;if(newStartIndex!==this.startIndex){this.startIndex=newStartIndex;this.renderDom();}}
renderDom(){[this.offsets,this.hexview,this.textview].forEach(view=>view.innerHTML='');const lineHeight=16;const totalLines=Math.ceil(this.data.length/this.bytesPerRow);const contentHeight=totalLines*lineHeight;[this.offsets,this.hexview,this.textview].forEach(view=>view.style.height=`${contentHeight}px`);const offsetsFragment=document.createDocumentFragment();const hexviewFragment=document.createDocumentFragment();const textviewFragment=document.createDocumentFragment();const startLine=Math.floor(this.startIndex/this.bytesPerRow);const endIndex=Math.min(this.startIndex+this.visibleByteCount,this.data.length);const endLine=Math.ceil(endIndex/this.bytesPerRow);const paddingTop=startLine*lineHeight;this.offsets.style.paddingTop=paddingTop+'px';this.hexview.style.paddingTop=paddingTop+'px';this.textview.style.paddingTop=paddingTop+'px';for(let line=startLine;line<endLine;line++){const i=line*this.bytesPerRow;const offsetSpan=document.createElement("span");offsetSpan.innerText=i.toString(16).padStart(8,'0');offsetsFragment.appendChild(offsetSpan);const hexLine=document.createElement('div');hexLine.classList.add('hex-line');const textLine=document.createElement('div');textLine.classList.add('text-line');for(let j=0;j<this.bytesPerRow&&i+j<this.data.length;j++){const index=i+j;const byte=this.data[index];const hexSpan=document.createElement('span');hexSpan.textContent=byte.toString(16).padStart(2,'0');hexSpan.dataset.byteIndex=index;this.matches.forEach(match=>{if(index>=match.index&&index<match.index+match.length){hexSpan.classList.add('search-highlight');}});hexLine.appendChild(hexSpan);const charSpan=document.createElement('span');let text=_byteToChar(byte);if(text===" ")text="\u00A0";else if(text==="-")text="\u2011";charSpan.textContent=text;charSpan.dataset.byteIndex=index;if(text===_NON_PRINTABLE_CHAR){charSpan.classList.add("non-printable");}
this.matches.forEach(match=>{if(index>=match.index&&index<match.index+match.length){charSpan.classList.add('search-highlight');}});textLine.appendChild(charSpan);}
hexviewFragment.appendChild(hexLine);textviewFragment.appendChild(textLine);}
this.offsets.appendChild(offsetsFragment);this.hexview.appendChild(hexviewFragment);this.textview.appendChild(textviewFragment);this.updateSelection();}
updateSelection(){if(this.previousSelectedIndex!==null){const prevHexSpan=this.hexview.querySelector(`span[data-byte-index="${this.previousSelectedIndex}"]`);const prevTextSpan=this.textview.querySelector(`span[data-byte-index="${this.previousSelectedIndex}"]`);if(prevHexSpan&&prevTextSpan){prevHexSpan.classList.remove('active-view-cursor');prevTextSpan.classList.remove('active-view-cursor');const wasInMatch=this.matches.some(match=>this.previousSelectedIndex>=match.index&&this.previousSelectedIndex<match.index+match.length);if(wasInMatch){prevHexSpan.classList.add('highlighted');prevTextSpan.classList.add('highlighted');}else{prevHexSpan.classList.remove('highlighted');prevTextSpan.classList.remove('highlighted');}}}
Array.from(this.hexedit.querySelectorAll(".active-view-cursor, .passive-view-cursor, .highlighted")).forEach(e=>e.classList.remove("active-view-cursor","passive-view-cursor","highlighted"));if(this.selectedIndex===null)return;if(this.selectedIndex>=this.startIndex&&this.selectedIndex<this.startIndex+this.visibleByteCount){const hexSpan=this.hexview.querySelector(`span[data-byte-index="${this.selectedIndex}"]`);const textSpan=this.textview.querySelector(`span[data-byte-index="${this.selectedIndex}"]`);if(hexSpan&&textSpan){const isInMatch=this.matches.some(match=>this.selectedIndex>=match.index&&this.selectedIndex<match.index+match.length);this.previousSelectedIndex=this.selectedIndex;if(this.activeView==='hex'){hexSpan.classList.add("active-view-cursor");textSpan.classList.add("passive-view-cursor");}else if(this.activeView==='text'){textSpan.classList.add("active-view-cursor");hexSpan.classList.add("passive-view-cursor");}
if(isInMatch){if(this.activeView==='hex'){hexSpan.classList.add('highlighted');}else if(this.activeView==='text'){textSpan.classList.add('highlighted');}}
if(this.activeView==='hex'){this.editHex=true;}else if(this.activeView==='text'){this.editHex=false;}
this.focusActiveView();}}}
focusActiveView(){if(this.activeView==='hex'){this.hexview.focus();}else if(this.activeView==='text'){this.textview.focus();}}
_registerEventHandlers(){this.hexview.tabIndex=0;this.textview.tabIndex=0;this.hexview.addEventListener("focus",()=>{this.activeView='hex';this.updateSelection();});this.textview.addEventListener("focus",()=>{this.activeView='text';this.updateSelection();});this.hexview.addEventListener("click",e=>{if(e.target.dataset.byteIndex===undefined)return;const index=parseInt(e.target.dataset.byteIndex);this.currentEdit="";this.editHex=true;this.setSelectedIndex(index);this.hexview.focus();});this.textview.addEventListener("click",e=>{if(e.target.dataset.byteIndex===undefined)return;const index=parseInt(e.target.dataset.byteIndex);this.currentEdit="";this.editHex=false;this.setSelectedIndex(index);this.textview.focus();});this.hexedit.addEventListener("keydown",e=>{if(e.target.tagName.toLowerCase()==='input')return;if(e.key==="Control")this.ctrlPressed=true;if(this.selectedIndex===null||this.ctrlPressed)return;if(e.key==="Escape"){this.currentEdit="";this.setSelectedIndex(null);return;}
if(this.readonly){const offsetChange=_keyShouldApply(e)??0;this.setSelectedIndex(this.selectedIndex+offsetChange);return;}
const key=e.key;if(this.editHex&&key.length===1&&key.match(/[0-9a-fA-F]/)){this.currentEdit+=key;e.preventDefault();if(this.currentEdit.length===2){const value=parseInt(this.currentEdit,16);this.setValueAt(this.selectedIndex,value);this.currentEdit="";this.setSelectedIndex(this.selectedIndex+1);}}else if(!this.editHex&&key.length===1){const value=key.charCodeAt(0);this.setValueAt(this.selectedIndex,value);this.setSelectedIndex(this.selectedIndex+1);e.preventDefault();}else{const offsetChange=_keyShouldApply(e);if(offsetChange){this.setSelectedIndex(this.selectedIndex+offsetChange);e.preventDefault();}}});this.hexedit.addEventListener("keyup",e=>{if(e.key==="Control")this.ctrlPressed=false;});this.hexeditContent.addEventListener('scroll',this.handleScroll.bind(this));}
setValueAt(index,value){this.data[index]=value;if(index>=this.startIndex&&index<this.startIndex+this.visibleByteCount){const hexSpan=this.hexview.querySelector(`span[data-byte-index="${index}"]`);const textSpan=this.textview.querySelector(`span[data-byte-index="${index}"]`);if(hexSpan)hexSpan.textContent=value.toString(16).padStart(2,'0');if(textSpan){let text=_byteToChar(value);if(text===" ")text="\u00A0";else if(text==="-")text="\u2011";textSpan.textContent=text;if(text===_NON_PRINTABLE_CHAR){textSpan.classList.add("non-printable");}else{textSpan.classList.remove("non-printable");}}}}
setSelectedIndex(index){this.selectedIndex=index;if(index!==null){const lineNumber=Math.floor(index/this.bytesPerRow);const lineHeight=16;const scrollTop=lineNumber*lineHeight;const visibleStartLine=Math.floor(this.hexeditContent.scrollTop/lineHeight);const visibleEndLine=visibleStartLine+this.visibleRows;if(lineNumber<visibleStartLine||lineNumber>=visibleEndLine){const newScrollTop=Math.max(0,(lineNumber*lineHeight)-((this.visibleRows/2)*lineHeight));this.hexeditContent.scrollTop=newScrollTop;}}
this.updateSelection();}
updateSearchStatus(searchType,current,total){['ascii','hex','regex'].forEach(type=>{const statusElement=document.getElementById(`hexedit-search-status-${type}`);if(type===searchType){statusElement.textContent=`${current}/${total}`;}else{statusElement.textContent=`0/0`;}});}}
function _fillHexeditDom(hexedit){hexedit.classList.add("hexedit");hexedit.tabIndex=-1;const offsetsHeader=document.createElement("div");offsetsHeader.classList.add("offsets-header");offsetsHeader.innerText=_("Offset (h)");const hexviewHeader=document.createElement("div");hexviewHeader.classList.add("hexview-header");for(let i=0;i<16;i++){const span=document.createElement("span");span.innerText=i.toString(16).toUpperCase().padStart(2,"0");hexviewHeader.appendChild(span);}
const textviewHeader=document.createElement("div");textviewHeader.classList.add("textview-header");textviewHeader.innerText=_("Decoded Text");const headersContainer=document.createElement("div");headersContainer.classList.add("hexedit-headers");headersContainer.appendChild(offsetsHeader);headersContainer.appendChild(hexviewHeader);headersContainer.appendChild(textviewHeader);const offsets=document.createElement("div");offsets.classList.add("offsets");const hexview=document.createElement("div");hexview.classList.add("hexview");const textview=document.createElement("div");textview.classList.add("textview");const contentContainer=document.createElement("div");contentContainer.classList.add("hexedit-content");contentContainer.appendChild(offsets);contentContainer.appendChild(hexview);contentContainer.appendChild(textview);hexedit.appendChild(headersContainer);hexedit.appendChild(contentContainer);hexedit.offsets=offsets;hexedit.hexview=hexview;hexedit.textview=textview;hexedit.headersContainer=headersContainer;hexedit.contentContainer=contentContainer;return hexedit;}
function _keyShouldApply(event){if(event.key==="Enter")return 1;if(event.key==="Tab")return 1;if(event.key==="Backspace")return-1;if(event.key==="ArrowLeft")return-1;if(event.key==="ArrowRight")return 1;if(event.key==="ArrowUp")return-16;if(event.key==="ArrowDown")return 16;return null;}
return L.Class.extend({initialize:function(hexeditDomObject){return new HexEditor(hexeditDomObject);}});