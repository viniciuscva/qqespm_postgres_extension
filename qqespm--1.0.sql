DROP FUNCTION IF EXISTS distance_constraint CASCADE;
CREATE OR REPLACE FUNCTION distance_constraint(keyword1 text, keyword2 text, min_distance float, max_distance float,
    first_excludes_second boolean, second_excludes_first boolean)
  RETURNS jsonb
AS $$
DECLARE
    exclusion_sign text;
    result jsonb;
BEGIN
    IF min_distance < 0 OR max_distance <= min_distance THEN
        RAISE EXCEPTION 'Invalid min or max distance';
        RETURN NULL;
    END IF;

    IF keyword1 = keyword2 THEN
        RAISE EXCEPTION 'Invalid pair of keywords. They must be different from each other';
        RETURN NULL;
    END IF;

    IF first_excludes_second AND second_excludes_first THEN
        exclusion_sign := '<>';
    ELSIF first_excludes_second THEN
        exclusion_sign := '>';
    ELSIF second_excludes_first THEN
        exclusion_sign := '<';
    ELSE
        exclusion_sign := '-';
    END IF;

    result := jsonb_build_object(
        'keyword1', keyword1,
        'keyword2', keyword2,
        'min_distance', min_distance,
        'max_distance', max_distance,
        'exclusion_sign', exclusion_sign
    );

	RETURN result;
END;
$$ LANGUAGE plpgsql;

-- select distance_constraint('school', 'bank', 0, 1000, true, false);

DROP FUNCTION IF EXISTS connectivity_constraint CASCADE;
DROP FUNCTION IF EXISTS connectivity_constraint;
CREATE OR REPLACE FUNCTION connectivity_constraint(keyword1 text, keyword2 text, topological_relation text)
  RETURNS jsonb
AS $$
DECLARE
    result jsonb;
BEGIN
    IF topological_relation NOT IN ('intersects', 'contains', 'within') THEN
        RAISE EXCEPTION 'Invalid topological relation. Choose one among (intersects, contains, within)';
        RETURN NULL;
    END IF;

    result := jsonb_build_object(
        'keyword1', keyword1,
        'keyword2', keyword2,
        'topological_relation', topological_relation
    );

	RETURN result;
END;
$$ LANGUAGE plpgsql;

-- select connectivity_constraint('gym', 'mall', 'within');

DROP FUNCTION IF EXISTS get_keywords_columns CASCADE;
DROP FUNCTION IF EXISTS get_keywords_columns;
CREATE OR REPLACE FUNCTION get_keywords_columns(pois_table_name text)
  RETURNS text[]
AS $$
DECLARE
    keywords_columns text[];
    result json;
BEGIN
	-- RETURN QUERY
    SELECT array_agg(column_name)
    INTO keywords_columns
    FROM information_schema.columns
    WHERE table_name = pois_table_name
        AND column_name NOT IN ('osm_id', 'geometry', 'name', 'centroid', 'lon', 'lat', 'id');

    IF array_length(keywords_columns, 1) IS NULL THEN
        RAISE EXCEPTION 'Table % not found or has no suitable columns', pois_table_name;
        -- RETURN NULL;
    END IF;

	RETURN keywords_columns;
END;
$$ LANGUAGE plpgsql;

-- select get_keywords_columns('pois');

DROP FUNCTION IF EXISTS get_keywords_frequencies CASCADE;
DROP FUNCTION IF EXISTS get_keywords_frequencies;
CREATE OR REPLACE FUNCTION get_keywords_frequencies(keywords text[], pois_table_name text, keyword_columns text[])
  RETURNS jsonb
AS $$
DECLARE
    keywords_frequencies jsonb;
    keyword_frequency bigint;
    keyword text;
    condition_for_keyword text;
    sql_query text;
	columnname text;
BEGIN
	-- return json_array_elements_text(json_build_array(keyword_columns_json));
    -- keyword_columns := (SELECT array_agg(value::text) FROM json_build_array(keyword_columns_json));

    IF array_length(keyword_columns, 1) IS NULL THEN
        RAISE EXCEPTION 'Invalid or empty keyword columns JSON';
        RETURN NULL;
    END IF;

    keywords_frequencies := '{}'::JSONB;

    FOREACH keyword IN ARRAY keywords 
	LOOP
        condition_for_keyword := '';
        FOREACH columnname IN ARRAY keyword_columns 
		LOOP
            IF condition_for_keyword <> '' 
			THEN
                condition_for_keyword := condition_for_keyword || ' OR ';
            END IF;
            condition_for_keyword := condition_for_keyword || columnname || ' = ' || quote_literal(keyword);
        END LOOP;

        sql_query := 'SELECT count(*) FROM ' || quote_ident(pois_table_name) || ' WHERE (' || condition_for_keyword || ')';
        EXECUTE sql_query INTO keyword_frequency;

        keywords_frequencies := jsonb_set(keywords_frequencies, ARRAY[keyword], to_jsonb(keyword_frequency));
    END LOOP;

	RETURN keywords_frequencies;
END;
$$ LANGUAGE plpgsql;

-- select get_keywords_frequencies(array['school', 'bank'], 'pois', get_keywords_columns('pois'));


DROP FUNCTION IF EXISTS build_exclusion_check CASCADE;
CREATE OR REPLACE FUNCTION build_exclusion_check(
    lij FLOAT,
    sign TEXT,
    tb_vi_name TEXT,
    tb_vj_name TEXT
) RETURNS TEXT AS $$
DECLARE
    exclusion_check TEXT := '';
BEGIN
    IF sign = '>' THEN
        exclusion_check := 'NOT EXISTS (SELECT 1 FROM ' || tb_vj_name || ' aux WHERE ST_DWithin(aux.centroid::geography, ' || tb_vi_name || '.centroid::geography, ' || lij || ', false)) ';
    ELSIF sign = '<' THEN
        exclusion_check := 'NOT EXISTS (SELECT 1 FROM ' || tb_vi_name || ' aux WHERE ST_DWithin(' || tb_vj_name || '.centroid::geography, aux.centroid::geography, ' || lij || ', false)) ';
    ELSIF sign = '<>' THEN
        exclusion_check := 'NOT EXISTS (SELECT 1 FROM ' || tb_vj_name || ' aux1 WHERE ST_DWithin(aux1.centroid::geography, ' || tb_vi_name || '.centroid::geography, ' || lij || ', false)) AND ' || E'\n' ||
                           'NOT EXISTS (SELECT 1 FROM ' || tb_vi_name || ' aux2 WHERE ST_DWithin(' || tb_vj_name || '.centroid::geography, aux2.centroid::geography, ' || lij || ', false))';
    END IF;

    RETURN exclusion_check;
END;
$$ LANGUAGE plpgsql;

-- SELECT build_exclusion_check(100, '<>', 'school', 'pharmacy');


DROP FUNCTION IF EXISTS with_clause_temporary_tables_all_keywords CASCADE;
CREATE OR REPLACE FUNCTION with_clause_temporary_tables_all_keywords(
    keywords TEXT[],
    pois_table_name TEXT,
    keywords_columns TEXT[]
) RETURNS TEXT AS $$
DECLARE
    expression TEXT := 'WITH' || E'\n';
    with_clauses TEXT[];
    keyword TEXT;
    keyword_column TEXT;
    keyword_columns_checks TEXT[];
    condition_for_keyword TEXT;
    with_clause_temporary_table_keyword TEXT;
BEGIN
    -- Loop over each keyword
    FOREACH keyword IN ARRAY keywords LOOP
        -- Clear the checks array for each keyword
        keyword_columns_checks := ARRAY[]::TEXT[];
        
        -- Loop over each keyword column to build the condition
        FOREACH keyword_column IN ARRAY keywords_columns LOOP
            keyword_columns_checks := array_append(keyword_columns_checks, keyword_column || ' = ''' || keyword || ''' ');
        END LOOP;

        -- Join the conditions with ' OR '
        condition_for_keyword := array_to_string(keyword_columns_checks, ' OR ');

        -- Create the WITH clause for the current keyword
        with_clause_temporary_table_keyword := '    _tb_' || keyword || ' AS' || E'\n' ||
            '        (SELECT * FROM ' || pois_table_name || ' WHERE ' || condition_for_keyword || ')';

        -- Append the clause to the with_clauses array
        with_clauses := array_append(with_clauses, with_clause_temporary_table_keyword);
    END LOOP;

    -- Join all the with_clauses with ',\n'
    expression := expression || array_to_string(with_clauses, ',' || E'\n');

    RETURN expression;
END;
$$ LANGUAGE plpgsql;

-- SELECT with_clause_temporary_tables_all_keywords(
--     ARRAY['keyword1', 'keyword2'],
--     'pois',
--     ARRAY['column1', 'column2']
-- );


DROP FUNCTION IF EXISTS select_clause_all_keywords CASCADE;
CREATE OR REPLACE FUNCTION select_clause_all_keywords(
    keywords TEXT[],
    use_alias BOOLEAN DEFAULT TRUE,
    include_centroids BOOLEAN DEFAULT FALSE
) RETURNS TEXT AS $$
DECLARE
    temporary_table_names TEXT[];
    select_clause TEXT;
	keyword TEXT;
    ttn_ TEXT;
BEGIN
    -- Generate temporary table names
    FOREACH keyword IN ARRAY keywords LOOP
		ttn_ := '_tb_' || keyword;
        temporary_table_names := array_append(temporary_table_names, ttn_);
    END LOOP;

    -- Build the select clause
    IF NOT include_centroids THEN
        IF use_alias THEN
            select_clause := 'SELECT ' || array_to_string(
                ARRAY(
                    SELECT ttn || '.osm_id AS ' || ttn || '_id'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            );
        ELSE
            select_clause := 'SELECT ' || array_to_string(
                ARRAY(
                    SELECT ttn || '_id'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            );
        END IF;
    ELSE
        IF use_alias THEN
            select_clause := 'SELECT ' || array_to_string(
                ARRAY(
                    SELECT ttn || '.osm_id AS ' || ttn || '_id'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            ) || ', ' || array_to_string(
                ARRAY(
                    SELECT ttn || '.centroid AS ' || ttn || '_centroid'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            );
        ELSE
            select_clause := 'SELECT ' || array_to_string(
                ARRAY(
                    SELECT ttn || '_id'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            ) || ', ' || array_to_string(
                ARRAY(
                    SELECT ttn || '_centroid'
                    FROM unnest(temporary_table_names) AS ttn
                ), ', '
            );
        END IF;
    END IF;

    RETURN select_clause;
END;
$$ LANGUAGE plpgsql;

-- SELECT select_clause_all_keywords(
--     ARRAY['school', 'bank']
-- );

DROP FUNCTION IF EXISTS from_clause_all_keywords CASCADE;
CREATE OR REPLACE FUNCTION from_clause_all_keywords(
    keywords TEXT[]
) RETURNS TEXT AS $$
DECLARE
    temporary_table_names TEXT[];
    expression TEXT;
BEGIN
    -- Generate temporary table names
    SELECT ARRAY_AGG('_tb_' || k)
    INTO temporary_table_names
    FROM unnest(keywords) AS k;

    -- Build the FROM clause
    expression := 'FROM ' || array_to_string(temporary_table_names, ', ');

    RETURN expression;
END;
$$ LANGUAGE plpgsql;

-- SELECT from_clause_all_keywords(
--     ARRAY['school', 'bank']
-- );


DROP FUNCTION IF EXISTS get_spatial_pattern_json_from_constraints CASCADE;
CREATE OR REPLACE FUNCTION get_spatial_pattern_json_from_constraints(constraints JSONB[])
RETURNS JSONB AS $$
DECLARE
    vertices JSONB[] := '{}';
    edges JSONB[] := '{}';
    constraint_ JSONB;
    wi TEXT;
    wj TEXT;
    vi JSONB;
    vj JSONB;
    edge JSONB;
    existing_edge JSONB;
    added_keywords TEXT[];
    added_edges JSONB[];
    relation TEXT;
    lij INTEGER;
    uij INTEGER;
    sign TEXT;
    vertex_index INTEGER;
    vertex JSONB;
    edge_index INTEGER;
    next_vertex_id INTEGER;
    vertices_keywords TEXT[];
    keyword TEXT;
    vi_vj_pairs TEXT[];
    vi_vj_pair TEXT;
BEGIN
    next_vertex_id := 0;
    FOR i IN 1..array_length(constraints, 1) LOOP
        constraint_ := constraints[i]; -- ::JSONB
        wi := constraint_ ->> 'keyword1';
        wj := constraint_ ->> 'keyword2';
        
        -- Check if wi is already in vertices
        vertices_keywords := '{}';
		vertex_index := NULL;
		FOREACH vertex IN ARRAY vertices
		LOOP
			keyword := vertex->>'keyword';
			vertices_keywords := array_append(vertices_keywords, keyword);
		END LOOP;
		SELECT INTO vertex_index array_position(vertices_keywords, wi);
        IF vertex_index IS NOT NULL THEN
            vi := vertices[vertex_index];
        ELSE
            vi := jsonb_build_object('id', next_vertex_id, 'keyword', wi);
            next_vertex_id := next_vertex_id + 1;
            vertices := array_append(vertices, vi);
        END IF;
        
        -- Check if wj is already in vertices jsonb_array_elements
        vertices_keywords := '{}';
		vertex_index := NULL;
		FOREACH vertex IN ARRAY vertices
		LOOP
			keyword := vertex->>'keyword';
			vertices_keywords := array_append(vertices_keywords, keyword);
		END LOOP;
        SELECT INTO vertex_index array_position(vertices_keywords, wj);
        IF vertex_index IS NOT NULL THEN
            vj := vertices[vertex_index];
        ELSE
            vj := jsonb_build_object('id', next_vertex_id, 'keyword', wj);
            next_vertex_id := next_vertex_id + 1;
            vertices := array_append(vertices, vj);
        END IF;
        
        -- Check if the edge already exists
        vi_vj_pairs := '{}';
		edge_index := NULL;
		FOREACH edge IN ARRAY edges
		LOOP
			vi_vj_pair := (edge->>'vi')::TEXT || '-' || (edge->>'vj')::TEXT;
			vi_vj_pairs := array_append(vi_vj_pairs, vi_vj_pair);
		END LOOP;
		-- RAISE NOTICE 'The value of vi.id is: %', vi->>'id';
		-- RAISE NOTICE 'The value of vj.id: %', vj->>'id';
		SELECT INTO edge_index array_position(vi_vj_pairs, (vi->>'id')::TEXT || '-' || (vj->>'id')::TEXT);
		IF edge_index IS NULL THEN
			SELECT INTO edge_index array_position(vi_vj_pairs, (vj->>'id')::TEXT || '-' || (vi->>'id')::TEXT);
		END IF;
        
        IF edge_index IS NOT NULL THEN
            existing_edge := edges[edge_index];
            IF constraint_ ? 'topological_relation' THEN
                existing_edge := jsonb_set(existing_edge, '{relation}', constraint_ -> 'topological_relation');
            END IF;
            IF constraint_ ? 'min_distance' THEN
                existing_edge := jsonb_set(existing_edge, '{lij}', constraint_ -> 'min_distance');
            END IF;
            IF constraint_ ? 'max_distance' THEN
                existing_edge := jsonb_set(existing_edge, '{uij}', constraint_ -> 'max_distance');
            END IF;
            IF constraint_ ? 'exclusion_sign' THEN
                existing_edge := jsonb_set(existing_edge, '{sign}', constraint_ -> 'exclusion_sign');
            END IF;
            edges[edge_index] := existing_edge;
        ELSE
            relation := constraint_ ->> 'topological_relation';
            lij := COALESCE((constraint_ ->> 'min_distance')::INTEGER, 0);
            uij := COALESCE((constraint_ ->> 'max_distance')::INTEGER, 10000);
            sign := COALESCE(constraint_ ->> 'exclusion_sign', '-');
            edge := jsonb_build_object(
                'id', (vi->>'id')::TEXT || '-' || (vj->>'id')::TEXT,
                'vi', vi->'id',
                'vj', vj->'id',
                'lij', lij,
                'uij', uij,
                'sign', sign,
                'relation', relation
            );
            edges := array_append(edges, edge);
        END IF;
    END LOOP;
    
    IF array_length(vertices, 1) < 2 OR array_length(edges, 1) = 0 THEN
        RAISE NOTICE 'Did not provide enough vertices or edges to create spatial pattern.';
        RETURN NULL;
    END IF;
    
	RAISE NOTICE 'Total vertices: %', array_length(vertices, 1);
    RETURN jsonb_build_object('vertices', vertices, 'edges', edges);
END;
$$ LANGUAGE plpgsql;

-- SELECT get_spatial_pattern_json_from_constraints(ARRAY[
-- 	distance_constraint('school', 'bank', 0, 1000, true, false),
-- 	connectivity_constraint('school', 'bank', 'within')
-- ]);


DROP FUNCTION IF EXISTS condition_clause_for_multiple_edges CASCADE;
CREATE OR REPLACE FUNCTION condition_clause_for_multiple_edges(
    sp_json JSONB
) RETURNS TEXT AS $$
DECLARE
    condition_clauses TEXT[];
    edge_record JSONB;
    vi JSONB;
    wi TEXT;
    vj JSONB;
    wj TEXT;
    tb_vi_name TEXT;
    tb_vj_name TEXT;
    lij FLOAT;
    uij FLOAT;
    sign TEXT;
    relation TEXT;
    distance_check TEXT := '';
    exclusion_check TEXT := '';
    relation_check TEXT := '';
    relations_to_postgis_functions JSONB := '{"contains":"ST_Covers", "within":"ST_CoveredBy", "intersects":"ST_Intersects", "disjoint":"ST_Disjoint"}'::JSONB;
BEGIN
    -- Loop over each edge
    FOR edge_record IN SELECT * FROM jsonb_array_elements(sp_json->'edges') LOOP
        -- Find vi vertex and get keyword wi
        SELECT INTO vi
            v
        FROM jsonb_array_elements(sp_json->'vertices') AS v
        WHERE v->>'id' = edge_record->>'vi';

        wi := vi->>'keyword';
        tb_vi_name := '_tb_' || wi;

        -- Find vj vertex and get keyword wj
        SELECT INTO vj
            v
        FROM jsonb_array_elements(sp_json->'vertices') AS v
        WHERE v->>'id' = edge_record->>'vj';

        wj := vj->>'keyword';
        tb_vj_name := '_tb_' || wj;

        lij := (edge_record->>'lij')::FLOAT;
        uij := (edge_record->>'uij')::FLOAT;
        sign := edge_record->>'sign';
        relation := edge_record->>'relation';

        -- Construct distance check
        IF lij > 0 AND uij < float 'inf' THEN
            distance_check := 'ST_DistanceSphere(' || tb_vi_name || '.centroid, ' || tb_vj_name || '.centroid) BETWEEN ' || lij || ' AND ' || uij;
        ELSIF lij = 0 AND uij < float 'inf' THEN
            distance_check := 'ST_DistanceSphere(' || tb_vi_name || '.centroid, ' || tb_vj_name || '.centroid) <= ' || uij;
        ELSIF lij > 0 AND uij = float 'inf' THEN
            distance_check := 'ST_DistanceSphere(' || tb_vi_name || '.centroid, ' || tb_vj_name || '.centroid) >= ' || lij;
        END IF;

        -- Construct exclusion check
        IF sign != '-' THEN
            exclusion_check := build_exclusion_check(lij, sign, tb_vi_name, tb_vj_name);  -- Assuming build_exclusion_check is a function that returns a condition string
        END IF;

        -- Construct relation check
        IF relation IS NOT NULL THEN
            relation_check := (relations_to_postgis_functions->>relation) || '(' || tb_vi_name || '.geometry, ' || tb_vj_name || '.geometry)';
        END IF;

        -- Gather necessary edge conditions
        IF distance_check != '' THEN
            condition_clauses := array_append(condition_clauses, distance_check);
        END IF;
        IF exclusion_check != '' THEN
            condition_clauses := array_append(condition_clauses, exclusion_check);
        END IF;
        IF relation_check != '' THEN
            condition_clauses := array_append(condition_clauses, relation_check);
        END IF;
    END LOOP;

    -- Join all condition clauses with ' AND '
    RETURN '    ' || array_to_string(condition_clauses, ' AND ');
END;
$$ LANGUAGE plpgsql;



-- SELECT condition_clause_for_multiple_edges(
-- 	get_spatial_pattern_json_from_constraints(ARRAY[
-- 		distance_constraint('school', 'bank', 0, 1000, true, false),
-- 		connectivity_constraint('school', 'bank', 'within')
-- 	])
-- );


DROP FUNCTION IF EXISTS build_sql_query_for_spatial_pattern_with_implicit_join CASCADE;
CREATE OR REPLACE FUNCTION build_sql_query_for_spatial_pattern_with_implicit_join(
    sp_json JSONB,
    pois_table_name TEXT,
    keywords_columns TEXT[],
    limit_ INT DEFAULT 100
) RETURNS TEXT AS $$
DECLARE
    keywords TEXT[];
    edges JSONB;
    limit_check TEXT := '';
    condition_clause TEXT;
    sql_query TEXT;
BEGIN
    -- Extract keywords from vertices in sp_json
    SELECT array_agg(v->>'keyword')
    INTO keywords
    FROM jsonb_array_elements(sp_json->'vertices') AS v;

    -- Extract edges from sp_json
    edges := sp_json->'edges';

    -- Determine limit check clause
    IF limit_ > 0 THEN
        limit_check := 'LIMIT ' || limit_;
    END IF;

    -- Generate condition clause for multiple edges
    condition_clause := '    ' || condition_clause_for_multiple_edges(sp_json);

    -- Generate the SQL query
    sql_query := with_clause_temporary_tables_all_keywords(keywords, pois_table_name, keywords_columns) || E'\n' ||
                 select_clause_all_keywords(keywords) || E'\n' ||
                 from_clause_all_keywords(keywords) || E'\n' || 'WHERE' || E'\n' ||
                 condition_clause || E'\n' ||
                 limit_check;

    RETURN sql_query;
END;
$$ LANGUAGE plpgsql;


-- SELECT build_sql_query_for_spatial_pattern_with_implicit_join(
--     get_spatial_pattern_json_from_constraints(ARRAY[
-- 		distance_constraint('school', 'bank', 0, 1000, true, false),
-- 		connectivity_constraint('school', 'bank', 'within')
-- 	]),
--     'pois',
--     get_keywords_columns('pois')
-- );


DROP FUNCTION IF EXISTS arrays_equal_unordered CASCADE;
CREATE OR REPLACE FUNCTION arrays_equal_unordered(arr1 TEXT[], arr2 TEXT[]) RETURNS BOOLEAN AS $$
DECLARE
    sorted_arr1 TEXT[];
    sorted_arr2 TEXT[];
BEGIN
    -- Check if arrays have the same length
    IF array_length(arr1, 1) != array_length(arr2, 1) THEN
        RETURN FALSE;
    END IF;

    -- Sort arrays and compare
    sorted_arr1 := (SELECT array_agg(elem ORDER BY elem) FROM unnest(arr1) AS elem);
    sorted_arr2 := (SELECT array_agg(elem ORDER BY elem) FROM unnest(arr2) AS elem);

    RETURN sorted_arr1 = sorted_arr2;
END;
$$ LANGUAGE plpgsql;

-- SELECT arrays_equal_unordered(
-- 	ARRAY['school', 'bank', 'pharmacy'],
-- 	ARRAY['bank', 'pharmacy', 'school']
-- );


DROP FUNCTION IF EXISTS get_vertex_from_id CASCADE;
CREATE OR REPLACE FUNCTION get_vertex_from_id(vertex_id INT, sp JSONB)
RETURNS JSONB AS $$
DECLARE
	vertex JSONB;
BEGIN
    FOR vertex IN SELECT * FROM jsonb_array_elements(sp->'vertices') LOOP
        IF vertex->>'id' = vertex_id::TEXT THEN
            RETURN vertex;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- SELECT get_vertex_from_id(
-- 	0, 
-- 	get_spatial_pattern_json_from_constraints(ARRAY[
-- 		distance_constraint('school', 'bank', 0, 1000, true, false),
-- 		connectivity_constraint('school', 'bank', 'within')
-- 	])
-- );


DROP FUNCTION IF EXISTS get_neighbors CASCADE;
CREATE OR REPLACE FUNCTION get_neighbors(vertex JSONB, sp JSONB)
RETURNS JSONB[] AS $$
DECLARE
    neighbors JSONB[] := '{}';
    edge JSONB;
    neighbor_vertex JSONB;
BEGIN
    FOR edge IN SELECT * FROM jsonb_array_elements(sp->'edges')
    LOOP
        IF (edge->>'vi')::TEXT = (vertex->>'id')::TEXT THEN
            neighbor_vertex := get_vertex_from_id((edge->'vj')::INT, sp);
            -- neighbors := jsonb_set(neighbors, '{999999}', neighbor_vertex, true);
            neighbors := neighbors || neighbor_vertex;
        ELSIF (edge->>'vj')::TEXT = (vertex->>'id')::TEXT THEN
        neighbor_vertex := get_vertex_from_id((edge->>'vi')::INT, sp);
            neighbors := neighbors || neighbor_vertex;
        END IF;
    END LOOP;
    RETURN neighbors;
END;
$$ LANGUAGE plpgsql;

-- SELECT get_neighbors(
--     '{"id":0, "keyword":"school"}'::JSONB, 
--     get_spatial_pattern_json_from_constraints(ARRAY[
-- 	    distance_constraint('school', 'bank', 0, 1000, true, false),
-- 	    connectivity_constraint('school', 'bank', 'within'),
-- 		distance_constraint('school', 'hospital', 0, 1000, true, false)
--     ])
-- );

DROP FUNCTION IF EXISTS remove_jsonb_values_from_array CASCADE;
CREATE OR REPLACE FUNCTION remove_jsonb_values_from_array(arr JSONB[], val JSONB)
RETURNS JSONB[] AS $$
DECLARE
    result JSONB[] := '{}'; -- Initialize an empty array to store the result
    element JSONB;
BEGIN
    FOREACH element IN ARRAY arr
    LOOP
        IF element != val THEN
            result := result || element; -- Append element to result if it is not equal to val
        END IF;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS get_greedy_search_path_by_keywords_frequencies CASCADE;
CREATE OR REPLACE FUNCTION get_greedy_search_path_by_keywords_frequencies(
    sp_json JSONB, 
    keyword_frequencies JSONB, 
    debug BOOLEAN DEFAULT FALSE
)
RETURNS JSONB[] AS $$
DECLARE
    sp JSONB := sp_json::JSONB;
    initial_vertex JSONB;
    current_vertex JSONB;
    next_vertex JSONB;
    vertices_sequence JSONB[] := '{}';
    remaining_edges JSONB[] := '{}';
    processed_edges JSONB[] := '{}';
    visited_vertices_with_remaining_edges JSONB[] := '{}';
    candidates_next_vertex JSONB[];
    edge JSONB;
    v JSONB;
    min_freq INT;
BEGIN
    IF debug THEN
        RAISE NOTICE 'Keyword frequencies: %', keyword_frequencies;
    END IF;

    -- Find the initial vertex
    initial_vertex := (
        SELECT vts
        FROM jsonb_array_elements(sp->'vertices') AS vts
        ORDER BY (keyword_frequencies->>(vts->>'keyword'))::INT
        LIMIT 1
    );

    -- Initialize variables
    remaining_edges := ARRAY(
        SELECT jsonb_build_array(e->>'vi', e->>'vj')
        FROM jsonb_array_elements(sp->'edges') AS e
    );

    current_vertex := initial_vertex;
    vertices_sequence := vertices_sequence || current_vertex;

	IF debug THEN
        RAISE NOTICE 'Initial vertex: %', initial_vertex;
    END IF;

    -- Main loop
    WHILE array_length(remaining_edges, 1) IS NOT NULL LOOP
		IF debug THEN
	        RAISE NOTICE 'Vertices sequence: %', vertices_sequence;
	    END IF;
        candidates_next_vertex := get_neighbors(current_vertex, sp);
        
    	FOREACH edge IN ARRAY processed_edges
        LOOP
            IF (edge->>0)::TEXT = (current_vertex->>'id')::TEXT THEN
                candidates_next_vertex := remove_jsonb_values_from_array(candidates_next_vertex, get_vertex_from_id((edge->>1)::INT, sp));
            ELSIF (edge->>1)::TEXT = (current_vertex->>'id')::TEXT THEN
                candidates_next_vertex := remove_jsonb_values_from_array(candidates_next_vertex, get_vertex_from_id((edge->>0)::INT, sp));
            END IF;
        END LOOP;

		RAISE NOTICE 'Total candidates next vertex after filtering proc. edges: %', array_length(candidates_next_vertex, 1);
		
        IF array_length(candidates_next_vertex, 1) IS NOT NULL THEN
            visited_vertices_with_remaining_edges := visited_vertices_with_remaining_edges || current_vertex;
            
            next_vertex := (
                SELECT cnv
                FROM unnest(candidates_next_vertex) AS cnv
                ORDER BY (keyword_frequencies->>(cnv->>'keyword'))::INT
                LIMIT 1
            );
            
            processed_edges := processed_edges || jsonb_build_array(current_vertex->>'id', next_vertex->>'id');
            remaining_edges := remove_jsonb_values_from_array(remaining_edges, jsonb_build_array(current_vertex->>'id', next_vertex->>'id'));
            remaining_edges := remove_jsonb_values_from_array(remaining_edges, jsonb_build_array(next_vertex->>'id', current_vertex->>'id'));
            
            current_vertex := next_vertex;
            IF NOT current_vertex::JSONB = ANY(vertices_sequence) THEN
                vertices_sequence := vertices_sequence || current_vertex;
            END IF;
        ELSE
            visited_vertices_with_remaining_edges := remove_jsonb_values_from_array(visited_vertices_with_remaining_edges, current_vertex);
            IF array_length(visited_vertices_with_remaining_edges, 1) IS NULL THEN
                RETURN vertices_sequence;
            END IF;
            current_vertex := (
                SELECT v
                FROM jsonb_array_elements(visited_vertices_with_remaining_edges) AS v
                ORDER BY (keyword_frequencies->>(v->>'keyword'))::INT
                LIMIT 1
            );
            IF NOT current_vertex::JSONB = ANY(vertices_sequence) THEN
                vertices_sequence := vertices_sequence || current_vertex;
            END IF;
        END IF;
    END LOOP;

    RETURN vertices_sequence;
END;
$$ LANGUAGE plpgsql;



-- SELECT get_greedy_search_path_by_keywords_frequencies(
--     get_spatial_pattern_json_from_constraints(ARRAY[
-- 	    distance_constraint('school', 'bank', 0, 1000, true, false),
-- 	    connectivity_constraint('school', 'bank', 'within'),
-- 		distance_constraint('school', 'hospital', 0, 1000, true, false)
--     ]), 
--     get_keywords_frequencies(array['school', 'bank','hospital'], 'pois', get_keywords_columns('pois'))
-- );


DROP FUNCTION IF EXISTS match_spatial_pattern CASCADE;
CREATE OR REPLACE FUNCTION match_spatial_pattern(
    spatial_constraints jsonb[],
    pois_table_name text,
    result_columns_order text[],
    max_results INT DEFAULT 100,
    join_method TEXT DEFAULT 'implicit'
)
RETURNS TABLE (
    obj_keyword1 bigint,
    obj_keyword2 bigint,
    obj_keyword3 bigint,
    obj_keyword4 bigint,
    obj_keyword5 bigint
) 
AS $$
DECLARE
    pois_table_name_exists BOOLEAN;
    sp_json JSONB;
    keywords TEXT[];
    keywords_columns TEXT[];
    keywords_frequencies JSONB;
    sql_query TEXT;
    record_ RECORD;
    keyword TEXT;
    i INTEGER;
    temp_id BIGINT;
    temp_results JSONB;
BEGIN
    -- Check if the POIs table exists
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_name = pois_table_name
    ) INTO pois_table_name_exists;

    -- Verify if the POIs table exists
    IF NOT pois_table_name_exists THEN
        RAISE EXCEPTION 'The specified table name % does not exist', pois_table_name;
    END IF;

    -- Generate the Spatial Pattern JSONB 
    sp_json := get_spatial_pattern_json_from_constraints(spatial_constraints);

    -- Get the keywords
    SELECT array_agg(v->>'keyword')
    INTO keywords
    FROM jsonb_array_elements(sp_json->'vertices') AS v;

    -- Verify if the keywords in the 'result_columns_order' are equivalent to the keywords in the 'spatial_constraints'
    IF NOT arrays_equal_unordered(keywords, result_columns_order) THEN
        RAISE EXCEPTION 'The names of the keywords in result_columns_order must match all the keywords in the spatial_constraints';
    END IF;

    keywords_columns := get_keywords_columns(pois_table_name);
    keywords_frequencies := get_keywords_frequencies(keywords, pois_table_name, keywords_columns);

    IF join_method = 'explicit' THEN
        -- TO BE IMPLEMENTED
        RAISE EXCEPTION 'Join method as Explicit has not yet been implemented';  
    ELSIF join_method = 'implicit' THEN
        sql_query := build_sql_query_for_spatial_pattern_with_implicit_join(
            sp_json,
            pois_table_name,
            keywords_columns,
            max_results
        );

        -- Execute the SQL query and iterate over the results
        FOR record_ IN EXECUTE sql_query LOOP
            -- Initialize the output variables
            obj_keyword1 := NULL;
            obj_keyword2 := NULL;
            obj_keyword3 := NULL;
            obj_keyword4 := NULL;
            obj_keyword5 := NULL;

            -- Convert the record to JSONB
            temp_results := to_jsonb(record_);

            -- Assign values to obj_keywordX based on result_columns_order
            FOR i IN 1..ARRAY_LENGTH(result_columns_order, 1) LOOP
                keyword := result_columns_order[i];
                IF i <= 5 THEN
                    -- Dynamically set the fields using JSONB
                    temp_id := (temp_results->>('_tb_' || keyword || '_id'))::bigint;
                    RAISE NOTICE 'Keyword: %, Temp ID: %', keyword, temp_id; -- Debugging line to check the values
                    -- Assign temp_id to the appropriate output variable
                    CASE i
                        WHEN 1 THEN obj_keyword1 := temp_id;
                        WHEN 2 THEN obj_keyword2 := temp_id;
                        WHEN 3 THEN obj_keyword3 := temp_id;
                        WHEN 4 THEN obj_keyword4 := temp_id;
                        WHEN 5 THEN obj_keyword5 := temp_id;
                    END CASE;
                END IF;
            END LOOP;

            -- Return the next row
            RETURN NEXT;
        END LOOP;
        
    ELSE
        RAISE EXCEPTION 'Invalid join_method. This value should be either "implicit" or "explicit"';
    END IF;

    -- End the function and return
    RETURN;
END;
$$ LANGUAGE plpgsql;


-- SELECT * FROM match_spatial_pattern(
--     array[
-- 		distance_constraint('school', 'pharmacy', 10, 10000, true, false) 
-- 	], 
-- 	'pois',
-- 	array['school', 'pharmacy']
-- );