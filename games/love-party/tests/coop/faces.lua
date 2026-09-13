-- Synthetic studio-format drawings for visual QA, not saved user profiles.
local json=require("vendor.json")
local faces={}
local patterns={
  {"  HHHHHHHH  "," HHHHHHHHHH "," SS SSSS SS "," SSSSSSSSSS "," SSWWSSWWSS "," SSWKSSWKSS "," SSSSSSSSSS "," SSSKKKKSSS ","  SSSSSSSS  "},
  {"   HHHHHH   "," HHHHHHHHHH "," HSSSSSSSSH "," SSSSSSSSSS "," SKKKSSKKKS "," SWKWSSWKWS "," SSSSSSSSSS "," SSSKWWKSSS ","  SSSSSSSS  "},
  {"  HHHHHHHH  "," HSSSSSSSSH "," SSSSSSSSSS "," SWWWSSWWWS "," SWKWSSWKWS "," SSSSSSSSSS "," SSKSSSSKSS ","  SKKKKKKS  ","   SSSSSS   "},
  {" HH      HH "," HHHHHHHHHH "," HSSSSSSSSH "," SSSSSSSSSS "," SSWWSSWWSS "," SSKWSSKWSS "," SSSSSSSSSS "," SSSKKKKSSS ","  SSSSSSSS  "},
}
for i,rows in ipairs(patterns) do
  local palette={S=({"#f2bc87","#bf805a","#9ed8a9","#bfadf1"})[i],H=({"#914958","#493b56","#eac451","#65519c"})[i],W="#ffffff",K="#192333"}
  local px={}; for n=1,48*48 do px[n]=json.null end
  for y,row in ipairs(rows) do for x=1,#row do px[(y+18)*48+x+16]=palette[row:sub(x,x)] or json.null end end
  faces[i]=json.encode({v=1,w=48,h=48,px=px})
end
return faces
