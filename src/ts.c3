module c3guide::ts;

// The few tree-sitter calls the outline needs (https://tree-sitter.github.io, runtime vendored in
// vendor/tree-sitter), and the C3 grammar's entry point (vendor/tree-sitter-c3). Layouts follow lib/include/tree_sitter/api.h.

struct TSParser { char opaque; }
struct TSTree { char opaque; }
struct TSLanguage { char opaque; }
struct TSPoint { uint row; uint column; }
struct TSNode { uint[4] context; void* id; void* tree; }

extern fn TSLanguage* tree_sitter_c3();
extern fn TSParser* ts_parser_new();
extern fn void ts_parser_delete(TSParser* parser);
extern fn bool ts_parser_set_language(TSParser* parser, TSLanguage* language);
extern fn TSTree* ts_parser_parse_string(TSParser* parser, TSTree* old_tree, char* source, uint length);
extern fn void ts_tree_delete(TSTree* tree);
extern fn TSNode ts_tree_root_node(TSTree* tree);
extern fn uint ts_node_named_child_count(TSNode node);
extern fn TSNode ts_node_named_child(TSNode node, uint index);
extern fn TSNode ts_node_child_by_field_name(TSNode node, char* name, uint length);
extern fn ZString ts_node_type(TSNode node);
extern fn uint ts_node_start_byte(TSNode node);
extern fn uint ts_node_end_byte(TSNode node);
extern fn TSPoint ts_node_start_point(TSNode node);
extern fn bool ts_node_is_null(TSNode node);
extern fn bool ts_node_has_error(TSNode node);
extern fn ZString ts_node_string(TSNode node);
