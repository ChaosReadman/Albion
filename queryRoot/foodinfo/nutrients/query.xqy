declare function se:hirakata($a as xs:string*) as xs:string external;

<DATA TYPE='JSON' OUTPATH="//DATA/LIST" FORCEARRAY="//LIST/FOOD">
(: 複数のFOODを返す場合には、その上位にラッパーを作り、OUTPATHに指定をする :)
(: FORCEARRAYはのラッパーの下位のFOODが１件の場合でもJSON配列で返すために指定する :)
<LIST>
{
(:PARAMS:)
let $searchstr := se:hirakata($id)

for $food in doc('food')//FOODS/FOOD
where contains($food/SEARCH_NAME,$searchstr) or contains($food/ADDITIONAL,$searchstr) or $food/@FOOD_ID=$searchstr or
      contains($food/SEARCH_NAME,$id) or contains($food/ADDITIONAL,$id)
order by $food/@FOOD_ID
return
  <FOOD>
    {$food/JP_DISP_NAME}
    <FOOD_ID>{$food/@FOOD_ID/string()}</FOOD_ID>
    <JP_NAME>{$food/JP_NAME}</JP_NAME>
    <ENERC_KCAL>{$food/ENERC_KCAL}</ENERC_KCAL>
    <PROT>{$food/PROT-}</PROT>
    <FAT>{$food/FAT-}</FAT>
    <CHOCDF>{$food/CHOCDF-}</CHOCDF>
    <VITA_RAE>{$food/VITA_RAE}</VITA_RAE>
    <TOCPHA>{$food/TOCPHA}</TOCPHA>
    <NE>{$food/NE}</NE>
    <ADDITIONAL>{$food/ADDITIONAL}</ADDITIONAL>
    <SEARCH_NAME>{$food/SEARCH_NAME}</SEARCH_NAME>
  </FOOD>
  }
</LIST>
</DATA>