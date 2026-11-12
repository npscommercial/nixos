# Image references from a Dockerfile's FROM lines, so Dependabot can keep them
# current. Stages are keyed by their AS name; a single unnamed FROM is "default".
lib: path: let
  lines = lib.splitString "\n" (builtins.readFile path);
  froms = builtins.filter (lib.hasPrefix "FROM ") lines;
  parse = line: let
    words = builtins.filter (w: w != "") (lib.splitString " " line);
    word = builtins.elemAt words;
  in
    if builtins.length words == 2
    then lib.nameValuePair "default" (word 1)
    else if builtins.length words == 4 && lib.toUpper (word 2) == "AS"
    then lib.nameValuePair (word 3) (word 1)
    else throw "${toString path}: unrecognised FROM line: ${line}";
in
  if froms == []
  then throw "${toString path}: no FROM line"
  else builtins.listToAttrs (map parse froms)
