<result>
{
    for $x in doc('mnt')//books/author/book
    where $x/../@name = "太宰治"
    return 
        <book title="{$x/@title}" price="{$x/@price}"/>
}
</result>
