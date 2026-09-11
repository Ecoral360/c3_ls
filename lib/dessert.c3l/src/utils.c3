module dessert::utils;

import std::collections::maybe;

macro @is_maybe($value) @const {
   return $Typeof($value)::is_generic(Maybe);
}

macro @is_maybe_expr(#value) {
  return $Typeof(#value)::is_generic(Maybe);
}

macro @is_maybe_type($Type) @const {
  return $Type::is_generic(Maybe);
}

macro @get_maybe_inner_type($Type) {
  $if @is_maybe_type($Type):
    return @get_maybe_inner_type($Type::generic_args[0]);
  $endif
  return $Type;
}

macro @get_tag($Type, String $tag_name, $default_val) @const @builtin => $Type::has_tag($tag_name) ??? $Type::get_tag($tag_name) : $default_val;

macro @rename(DFieldConfig $config, String $name, CaseConvention $convention) @const {
  $if $config.rename.len > 0:
    return $config.rename;
  $else
    $switch $convention:
      $case VERBATIM:
        return $name;

      $case CAMEL_CASE:
        return @str_camelcase($name);

      $case PASCAL_CASE:
        return @str_pascalcase($name);

      $case SNAKE_CASE:
        return @str_snakecase($name);

      $case CONSTANT_CASE:
        return @str_constantcase($name);

      $case LOWER_CASE:
        return @str_lower($name);

      $case UPPER_CASE:
        return @str_upper($name);

      $case KEBAB_CASE:
        return @str_replace(@str_snakecase($name), "_", "-");

      $default:
        $error @sprintf("CaseConvention %s not supported for now.", $convention);
    $endswitch
  $endif
}

fn String rename_enum_description(String name, CaseConvention convention) {
  switch (convention) {
    case VERBATIM:
      return name;

    case CAMEL_CASE:
      name = name.to_lower_tcopy();
      name.convert_snake_to_pascal();
      name[0] = ascii::@to_lower(name[0]);
      return name;

    case PASCAL_CASE:
      name = name.to_lower_tcopy();
      name.convert_snake_to_pascal();
      return name;

    case SNAKE_CASE:
      return name.to_lower_tcopy();

    case CONSTANT_CASE:
      return name;

    case LOWER_CASE:
      return name.to_lower_tcopy();

    case UPPER_CASE:
      return name;

    case KEBAB_CASE:
      name = name.to_lower_tcopy();
      return name.treplace("_", "-");
  }
}


<* thanks to @nonnorm for this helper macro ! *>
macro @method_fallback(des, #method, #fallback = ..., ...) <Interface> @private {
  var $method = $stringify(#method);
  $switch:
    $case $Typeof(des) == Interface:
      if (&des.$method) {
        return des.$method(...$vaarg);
      }
      $if $defined(#fallback):
        return #fallback;
      $endif

    $case $defined(des.$method):
      return des.$method(...$vaarg);

    $case $defined(#fallback):
      return #fallback;
    $default:
      $error "Must define a fallback";
  $endswitch
}

<* thanks to @nonnorm for this helper macro ! *>
macro @method_fallback_chain(des, #method, ..., #args = ...) <Interface> @private {
	var $method = $stringify(#method);
	$if $Typeof(des) == Interface:
		if (&des.$method) {
      $if $defined(#args):
        return des.$method(($Typefrom($Typeof(des.$method)::params[1].type)) #args);
      $else
        return des.$method();
      $endif
		}

		$for var $i = 0; $i < $vaarg.len; $i++:
			var $fallback = $stringify($vaarg[$i]);
			// Would prefer to use else if, but it probably doesn't matter
			if (&des.$fallback) {
        $if $defined(#args):
          return des.$fallback(($Typefrom($Typeof(des.$fallback)::params[1].type)) #args);
        $else
          return des.$fallback();
        $endif
			}
		$endfor
	$endif

	$if $defined(des.$method):
    $if $defined(#args):
      return des.$method(($Typefrom($Typeof(des.$method)::params[1].type)) #args);
    $else
      return des.$method();
    $endif
  $else
    $for var $i = 0; $i < $vaarg.len; $i++:
      var $fallback = $stringify($vaarg[$i]);
      $if $defined(des.$fallback):
        $if $defined(#args):
          return des.$fallback(($Typefrom($Typeof(des.$fallback)::params[1].type)) #args);
        $else
          return des.$fallback();
        $endif
      $endif
    $endfor
  $endif
}
