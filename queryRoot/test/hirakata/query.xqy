declare function se:hirakata($a as xs:string*) as xs:string external;

<result>
{
    (:PARAMS:)
    let $searchstr := se:hirakata($id)
    return $searchstr
}
</result>