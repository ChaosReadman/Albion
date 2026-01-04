declare function xs:hirakata($a as xs:string*) as xs:string external;


<DATA TYPE='JSON' OUTPATH="//DATA/FOODS" FORCEARRAY="//FOODS/FOOD">
  <FOODS>
{
(:PARAMS:)
let $searchstr := xs:hirakata($foodname)

for $food in doc('food')//FOODS/FOOD
where contains($food/SEARCH_NAME,$searchstr) or contains($food/ADDITIONAL,$searchstr) or $food/@FOOD_ID=$searchstr or
      contains($food/SEARCH_NAME,$foodname) or contains($food/ADDITIONAL,$foodname)
order by $food/@FOOD_ID
return
    <FOOD>
      <FOOD_ID>{$food/@FOOD_ID/string()}</FOOD_ID>
      <JP_NAME>{$food/JP_NAME}</JP_NAME>
      <JP_DISP_NAME>{$food/JP_DISP_NAME}</JP_DISP_NAME>
      <SEARCH_NAME>{$food/SEARCH_NAME}</SEARCH_NAME>
      <ADDITIONAL>{$food/ADDITIONAL}</ADDITIONAL>
    </FOOD>
}
  </FOODS>
</DATA>